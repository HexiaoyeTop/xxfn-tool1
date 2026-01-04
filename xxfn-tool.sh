#!/bin/bash

# ====================================================
# 工具名称：xxfn-tool (v2601021615)
# 适用设备：FnOS ARM (OEC / OECT 等ARM设备)
# 核心功能：三系统切换、系统升级、LED灯、MAC修改、热克隆
# aminsire@qq.com
# ====================================================

# LED / 路径设置
L_RED="/sys/class/leds/red:status/brightness"
L_GREEN="/sys/class/leds/green:status/brightness"
L_BLUE="/sys/class/leds/blue:status/brightness"
IMG_DIR="/vol1/1000/down"
BOOT_CONF="/boot/extlinux/extlinux.conf"
LED_CONF="/etc/oec-led.conf"

# 颜色定义
RED_C='\033[0;31m'
GREEN_C='\033[0;32m'
YELLOW_C='\033[1;33m'
BLUE_C='\033[38;5;39m'
PURPLE_C='\033[0;35m'
CYAN_C='\033[0;36m'
NC='\033[0m'

WEB_PID=""
WEB_STATUS="${RED_C}未开��?{NC}"

# --- 清理函数 ---
cleanup_web() {
    # 如果 PID 存在且进程还在运行，则杀掉它
    if [ -n "$WEB_PID" ] && kill -0 "$WEB_PID" 2>/dev/null; then
        kill $WEB_PID 2>/dev/null
        WEB_PID=""
        WEB_STATUS="${RED_C}未开��?{NC}"
        echo -e "${YELLOW_C}Web 服务已关闭��?{NC}"
    fi
}

# 【选择 1】：如果您希望“退出脚本即结束 Web”，请保留下面这一��?# 【选择 2】：如果您希望“退出不结束（常驻后台）”，请注释掉下面这一��?#trap cleanup_web EXIT

# ====================================================

# --- 环境自清��?(解决 mnt 目录及文件残��? ---
for tmp_path in /mnt/fn_tmp /mnt/data_tmp /mnt/check_sys /mnt/clone_tmp; do
    # 1. 检查是否挂载，如果是则卸载
    if mountpoint -q "$tmp_path"; then
        umount -l "$tmp_path" 2>/dev/null
    fi
    
    # 2. 只有在确定已经卸载的情况下，才执行强制删除目��?    if [ -d "$tmp_path" ] && ! mountpoint -q "$tmp_path"; then
        rm -rf "$tmp_path" 2>/dev/null
    fi
done
# ====================================================

# --- LED 持久化初始化 ---
init_led_service() {
    if [ ! -f /etc/systemd/system/oec-led.service ]; then
        echo -e "\n${YELLOW_C}>>> 正在初始化灯效持久化服务...${NC}"
        [ ! -f "$LED_CONF" ] && echo "0 1 1" > "$LED_CONF"
        cat << 'EOF' > /usr/local/bin/oec-led
#!/bin/bash
LED_CONF="/etc/oec-led.conf"
[ ! -f "$LED_CONF" ] && exit 0
read R G B < "$LED_CONF"
echo $R > /sys/class/leds/red:status/brightness 2>/dev/null
echo $G > /sys/class/leds/green:status/brightness 2>/dev/null
echo $B > /sys/class/leds/blue:status/brightness 2>/dev/null
EOF
        chmod +x /usr/local/bin/oec-led
        cat << 'EOF' > /etc/systemd/system/oec-led.service
[Unit]
Description=FnOS OEC LED Persistence Service
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/oec-led
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable oec-led.service >/dev/null 2>&1
        echo -e "${GREEN_C}>>> 服务初始化完成��?{NC}"
        sleep 1
    fi
}

set_led() {
    echo $1 > $L_RED 2>/dev/null
    echo $2 > $L_GREEN 2>/dev/null
    echo $3 > $L_BLUE 2>/dev/null
}

# --- 核心状态获取函��?---
get_status() {
    local root_dev=$(findmnt -n -o SOURCE /)
    if [[ "$root_dev" == *"/dev/sdb1"* ]]; then
        CURRENT_ENV="SATA 硬盘系统"
        ENV_CODE="SATA"
    elif [[ "$root_dev" == *"/dev/sda1"* ]]; then
        CURRENT_ENV="USB 硬盘系统"
        ENV_CODE="USB"
    elif [[ "$root_dev" == *"/dev/mmcblk0p2"* ]]; then
        CURRENT_ENV="eMMC 内置系统"
        ENV_CODE="EMMC"
    else
        CURRENT_ENV="未知系统"
        ENV_CODE="UNKNOWN"
    fi

    local next_root=$(grep -oP 'root=\K[^ ]+' "$BOOT_CONF")
    case "$next_root" in
        "/dev/sdb1") NEXT_BOOT="SATA 硬盘系统" ;;
        "/dev/sda1") NEXT_BOOT="USB 硬盘系统" ;;
        "/dev/mmcblk0p2") NEXT_BOOT="eMMC 内置系统" ;;
        *) NEXT_BOOT="未知 ($next_root)" ;;
    esac

    # 【核心逻辑】：实时找回后台运行��?Web 进程
    local existing_pid=$(lsof -t -i:5680 2>/dev/null | head -n 1)
    if [ -n "$existing_pid" ]; then
        WEB_PID="$existing_pid"
        local local_ip=$(ip addr show | grep -w inet | grep -v 127.0.0.1 | awk '{print $2}' | cut -d/ -f1 | head -n 1)
        WEB_STATUS="${GREEN_C}运行��?(PID: $WEB_PID) http://$local_ip:5680 ${NC}"
    else
        WEB_PID=""
        WEB_STATUS="${RED_C}未开��?{NC}"
    fi
}

# --- 校验目标分区是否存在系统 ---
check_system_exists() {
    local target_p=$1
    local target_name=$2
    if [ ! -b "$target_p" ]; then
        echo -e "${RED_C}错误: 未检测到 $target_name 分区 ($target_p)${NC}"
        echo -e "${YELLOW_C}请检查硬盘是否插入或是否已经进行[初始化分区]��?{NC}"
        return 1
    fi
    local tmp_mnt="/mnt/check_sys"
    mkdir -p $tmp_mnt
    mount -o ro "$target_p" $tmp_mnt 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED_C}错误: 无法读取 $target_name 分区，可能未格式化��?{NC}"
        return 1
    fi
    if [ ! -f "$tmp_mnt/sbin/init" ] && [ ! -f "$tmp_mnt/etc/fstab" ]; then
        umount $tmp_mnt
        echo -e "${RED_C}错误: ��?$target_name 分区中未检测到有效��?Linux 系统文件��?{NC}"
        echo -e "${YELLOW_C}请先通过[升级刷入新镜像]功能安装系统��?{NC}"
        return 1
    fi
    umount $tmp_mnt
    return 0
}

mac_manager() {
    echo -e "\n${CYAN_C}--- 修改 MAC 地址 ---${NC}"
    local iface=$(nmcli -t -f DEVICE,TYPE device | grep ethernet | head -n 1 | cut -d: -f1)
    [ -z "$iface" ] && iface=$(ls /sys/class/net | grep -v "lo" | head -n 1)
    local conn_name=$(nmcli -t -f NAME,TYPE connection show --active | grep ethernet | head -n 1 | cut -d: -f1)
    [ -z "$conn_name" ] && conn_name="Wired connection 1"
    local current_mac=$(cat /sys/class/net/$iface/address 2>/dev/null)
    echo -e "检测到网卡: $iface | 当前 MAC: $current_mac"
    read -p "请输入新 MAC (格式 00:11:22:33:44:55, 回车取消): " new_mac
    if [ -n "$new_mac" ] && [[ $new_mac =~ ^([a-fA-F0-9]{2}:){5}[a-fA-F0-9]{2}$ ]]; then
        echo -e "${YELLOW_C}正在应用��?MAC 地址...${NC}"
        nmcli connection modify "$conn_name" ethernet.cloned-mac-address "$new_mac"
        nmcli connection down "$conn_name" >/dev/null 2>&1
        nmcli connection up "$conn_name" >/dev/null 2>&1
        echo -e "${GREEN_C}>>> MAC 地址修改成功！网络已重新连接��?{NC}"
    fi
    read -p "按回车键返回菜单..." temp
}

ask_reboot() {
    echo -e "\n${GREEN_C}>>> 引导配置修改成功��?{NC}"
    echo -e "${YELLOW_C}提示：系统需要重启后才会进入新引导的系统��?{NC}"
    read -p "是否立即重启设备? (y/n): " res
    if [[ "$res" == "y" || "$res" == "Y" ]]; then
        echo "正在同步数据并准备重��?.."
        sync && reboot
    else
        echo -e "\n${CYAN_C}已取消重启，请稍后手动重启��?{NC}"
    fi
}

init_disk() {
    # --- 新增工具检��?---
    if ! command -v parted &> /dev/null || ! command -v mkfs.ext4 &> /dev/null; then
        echo -e "${RED_C}错误: 请切换sudo -i ��?系统缺少必要工具 (parted ��?e2fsprogs)${NC}"
        echo -e "${YELLOW_C}请先执行: apt update && apt install parted e2fsprogs -y${NC}"
        read -p "按回车返��?.." t; return
    fi
    # ------------------
    
    local dev=$1
    local name=$2
    if [ ! -b "$dev" ]; then
        echo -e "${RED_C}错误: 未检测到 $name ($dev)${NC}"
        read -p "按回车返��?.." t; return
    fi
    echo -e "${RED_C}!!! 警告: 此操作将清空 $name 上的所有数��?!!!${NC}"
    
    # --- 智能分区大小逻辑 ---
    read -p "请输入分��?(系统��?的大��?(例如 64, 默认 32): " part_size
    if [ -z "$part_size" ]; then
        part_size="32GiB"
    # 如果用户只输入了数字，默认补��?GiB（最推荐的单位）
    elif [[ "$part_size" =~ ^[0-9]+$ ]]; then
        part_size="${part_size}GiB"
    fi
    # --------------------------

    read -p "确定执行格式化并分区��? (y/n): " confirm
    if [ "$confirm" == "y" ]; then
        set_led 1 0 0
        echo -e "${YELLOW_C}正在清理并重新分��?..${NC}"
        umount ${dev}* &>/dev/null
        # 强制使用 GPT 分区��?        parted $dev -s mklabel gpt
        # 分区1：起始扇��?2048s (1MB对齐)，结束位置由变量决定
        parted $dev -s mkpart primary btrfs 2048s "$part_size"
        # 分区2：从分区1结束的位置开始，直到磁盘末尾 (100%)
        parted $dev -s mkpart primary ext4 "$part_size" 100%
        sync && sleep 2
        # 格式化数据分��?        mkfs.ext4 -F ${dev}2
        set_led 0 1 0
        echo -e "${GREEN_C}$name 初始化成功！(系统区大��? $part_size)${NC}"
    fi
    read -p "按回车键返回菜单..." temp
}

post_write_fix() {
    local target=$1
    local mnt="/mnt/fn_tmp"
    mkdir -p $mnt && mount $target $mnt
    
    echo -e "${CYAN_C}正在执行扩容��?fstab 局部修��?..${NC}"
    btrfs filesystem resize max $mnt &>/dev/null

    # 1. 备份原文��?    cp "$mnt/etc/fstab" "$mnt/etc/fstab.bak"

    # 2. 局部替换根分区设备 (仅修改开头的路径)
    # 逻辑：匹配所有以 / 为挂载点的行，将其开头的设备��?无论是UUID还是/dev/xxx)替换��?$target
    # 使用 [[:space:]] 确保匹配的是独立的挂载点��?    sed -i "s|^[^[:space:]]\+[[:space:]]\+\/[[:space:]]|$target         /        |" "$mnt/etc/fstab"

    # 3. 局部替��?/boot 分区设备 (强制指向 eMMC 第一分区)
    sed -i "s|^[^[:space:]]\+[[:space:]]\+\/boot[[:space:]]|/dev/mmcblk0p1   /boot   |" "$mnt/etc/fstab"

    umount $mnt && sync
    echo -e "${GREEN_C}fstab 修正完成 (已保留原参数)��?{NC}"
}

# --- 通用系统热克隆逻辑 ---
clone_system() {
    local src_dev="/"
    local target_dev=$1
    local target_name=$2
    local mnt="/mnt/clone_tmp"

    # 安全检查：防止自己克隆给自��?    local current_root=$(findmnt -n -o SOURCE /)
    if [[ "$current_root" == *"$target_dev"* ]]; then
        echo -e "${RED_C}错误: 目标分区 $target_dev 是当前正在运行的系统，无法克隆！${NC}"
        read -p "按回车返��?.." t; return
    fi

    echo -e "${YELLOW_C}即将开始系统热克隆: [当前系统] -> $target_name ($target_dev)...${NC}"
    echo -e "${RED_C}警告: 目标分区的数据将被彻底覆盖！${NC}"
    read -p "确认开始吗? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    #mkdir -p $mnt && mount $target_dev $mnt 2>/dev/null
    #if [ $? -ne 0 ]; then
    #    echo -e "${RED_C}错误: 无法挂载目标分区��?{NC}"
    #    read -p "按回车返��?.." t; return
    #fi
    echo -e "${YELLOW_C}正在强制刷新并准备目标分��?..${NC}"
    
    # 1. 尝试卸载所有相关占��?    umount -l "$target_dev" 2>/dev/null
    umount -l "$mnt" 2>/dev/null

    # 2. 【关键修复】：强制抹除旧文件系统头信息并格式化��?Btrfs
    # 这一步能解决 "failed to recognize exfat type" 的报��?    echo -e "${CYAN_C}正在执行强制格式��?(抹除旧残��?...${NC}"
    mkfs.btrfs -f "$target_dev" &>/dev/null
    
    # 3. 强制内核重读分区表并扫描
    partprobe "$target_dev" 2>/dev/null
    btrfs device scan 2>/dev/null
    sync && sleep 2

    # 4. 执行正式挂载
    mkdir -p "$mnt"
    mount -t btrfs "$target_dev" "$mnt" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        local error_msg=$(dmesg | tail -n 1)
        echo -e "${RED_C}错误: 依然无法挂载目标分区 $target_dev${NC}"
        echo -e "${YELLOW_C}最终建议：${NC}"
        echo -e " - 内核报错: $error_msg"
        echo -e " - 请尝试物理拔插硬盘后再运��?[初始化分区]${NC}"
        read -p "按回车返��?.." t; return
    fi

    # 【核心加入】：开��?Btrfs 透明压缩
    echo -e "${CYAN_C}正在开��?Btrfs 透明压缩 (zstd:3)...${NC}"
    btrfs property set "$mnt" compression zstd:3 2>/dev/null

    set_led 1 1 0  # 黄灯
    echo -e "${PURPLE_C}正在同步文件 (rsync)...${NC}"

    # 执行同步

    #rsync -av --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/mnt --exclude=/tmp --exclude=/boot --exclude=/media --exclude=/vol* / /$mnt/

    # 修正排除语法，增��?-H 保留硬链接，-X 保留扩展属性（对某些权限很重要��?    rsync -avHX --delete \
        --exclude=/proc --exclude=/sys --exclude=/dev \
        --exclude=/mnt --exclude=/tmp --exclude=/boot \
        --exclude=/media --exclude=/vol* --exclude=/lost+found \
        / $mnt/

    # 获取 rsync 的退出状��?    local res=$?

    # 【核心修复】：允许 0(完美), 23(部分文件属性报��?, 24(文件在传输时消失)
    if [ $res -eq 0 ] || [ $res -eq 23 ] || [ $res -eq 24 ]; then
        umount $mnt
        post_write_fix $target_dev
        set_led 0 1 0
        echo -e "${GREEN_C}>>> 系统克隆完成��?注：已忽略非致命的临时文件报��?${NC}"
        echo -e "${YELLOW_C}返回菜单��?切换引导重启后即可进入此系统${NC}"
    else
        set_led 1 0 0
        echo -e "${RED_C}>>> 克隆失败！rsync 错误��? $res${NC}"
        umount $mnt
    fi
    read -p "按回车键返回菜单..." temp
}

upgrade_logic() {
    local current_img_dir="$IMG_DIR"
    local mounted=0

    # --- 1. 自动挂载探测逻辑 ---
    if [ ! -d "$current_img_dir" ] || [ -z "$(ls $current_img_dir/*.img 2>/dev/null)" ]; then
        echo -e "${YELLOW_C}提示：默认镜像目��?current_img_dir未找到镜像，尝试探测硬盘数据分区...${NC}"
        local data_p="/dev/sda2"; [ "$3" == "USB" ] && data_p="/dev/sdb2"
        
        if [ -b "$data_p" ]; then
            read -p "检测到数据分区 $data_p，是否尝试挂载寻找镜��? (y/n): " try_mnt
            if [[ "$try_mnt" == "y" || "$try_mnt" == "Y" ]]; then
                current_img_dir="/mnt/data_tmp"
                mkdir -p "$current_img_dir"
                # 挂载分区
                mount "$data_p" "$current_img_dir" 2>/dev/null
                if [ $? -eq 0 ]; then
                    mounted=1
                    # 【核心修复】挂载后立即全开权限，解决无法上传问��?                    chmod 777 "$current_img_dir"
                    echo -e "\n${GREEN_C}已临时挂载数据盘，权限已全开(777)${NC}"
                    echo -e "${CYAN_C}请通过 WinSCP ��?FinalShell ��?.img 镜像上传到：${NC}"
                    echo -e "${CYAN_C}或通过 开启web上传服务��?使用浏览器进行上��?{NC}"
                    echo -e "${YELLOW_C}临时镜像目录: $current_img_dir${NC}"
                    echo -e "${BLUE_C}------------------------------------------------${NC}"
                    read -p "上传完成后，请按 [回车键] 继续扫描镜像: " wait_upload
                fi
            fi
        fi
    fi

    # --- 2. 手动模式 (如果自动挂载后还没找到文��? ---
    if [ -z "$(ls $current_img_dir/*.img 2>/dev/null)" ]; then
        echo -e "${RED_C}错误: ��?$current_img_dir 下未找到 .img 文件��?{NC}"
        read -p "请输入镜像文件所在的完整路径 (或回车退��?: " custom_path
        if [ -n "$custom_path" ] && [ -d "$custom_path" ]; then
            current_img_dir="$custom_path"
        else
            [ $mounted -eq 1 ] && umount /mnt/data_tmp 2>/dev/null
            return
        fi
    fi

    # --- 3. 刷入逻辑 (后面部分保持不变) ---
    local target_dev=$1; local target_name=$2; local mode=$3
    if [ "$ENV_CODE" == "$mode" ]; then
        echo -e "${RED_C}错误: 无法在运行中升级当前系统��?{NC}"
        [ $mounted -eq 1 ] && umount /mnt/data_tmp 2>/dev/null
        read -p "按回车返��?.." t; return
    fi

    imgs=($(ls $current_img_dir/*.img 2>/dev/null))
    echo -e "${GREEN_C}请选择要刷��?$target_name 的镜像：${NC}"
    select img in "${imgs[@]}"; do
        if [ -n "$img" ]; then
            set_led 1 0 1
            echo -e "\n${PURPLE_C}开始刷入，这通常需��?1-2 分钟，请勿断��?..${NC}"
            # 挂载镜像并获取分��? (FnOS系统分区一般在p2)
            local loop_dev=$(losetup -fP --show "$img")
            dd if="${loop_dev}p2" of=$target_dev bs=4M status=progress conv=fsync
            losetup -D
            post_write_fix $target_dev
            set_led 0 1 0
            [ $mounted -eq 1 ] && umount /mnt/data_tmp 2>/dev/null
            echo -e "\n${GREEN_C}>>> 系统升级完成��?{NC}"
            echo -e "${YELLOW_C}返回菜单��?切换引导重启后即可进入此系统${NC}"
            read -p "按回车键返回菜单..." temp; break
        else
            echo "无效选择，请重新输入编号��?
        fi
    done
}

# --- 16/17 Web 上传控制逻辑 ---
web_upload_toggle() {
    local mode=$1
    local py_script="/tmp/xxnas_file.py"

    if [ "$mode" == "on" ]; then
        if [ -n "$WEB_PID" ]; then
            echo -e "${YELLOW_C}提示：Web 上传服务已在运行��?{NC}"; sleep 1; return
        fi

        # 1. 校验本地脚本
        if [ -f "$py_script" ] && [ -s "$py_script" ]; then
            echo -e "${GREEN_C}>>> 检测到本地已存在服务脚本，正在启动...${NC}"
        else
            echo -e "${YELLOW_C}>>> 正在创建WEB上传服务脚本...${NC}"
            curl -s -L --retry 3 -o "$py_script" https://us1.vvvvvv.de5.net/sh/xxnas_file.py
            if [ $? -ne 0 ] || [ ! -f "$py_script" ]; then
                echo -e "${RED_C}错误：脚本创建失败，请检查网络或 /tmp 写入权限��?{NC}"
                sleep 1; return
            fi
            chmod +x "$py_script"
        fi

        # 2. 获取端口��?        local web_port
        read -p "请输入服务端��?(直接回车默认 5680): " web_port
        [ -z "$web_port" ] && web_port="5680"

        # 校验端口是否被占��?        if ss -tuln | grep -q ":$web_port "; then
            echo -e "${RED_C}错误：端��?$web_port 已被占用，请更换端口��?{NC}"
            sleep 1; return
        fi

        # 3. 设置访问密码
        local web_pass
        read -p "设置访问密码 (直接回车无密��?: " web_pass

        # 4. 获取本机 IP
        local local_ip=$(ip addr show | grep -w inet | grep -v 127.0.0.1 | awk '{print $2}' | cut -d/ -f1 | head -n 1)

        # 5. 启动服务逻辑
        if [ -n "$web_pass" ]; then
            python3 "$py_script" "$web_port" "$web_pass" >/dev/null 2>&1 &
        else
            python3 "$py_script" "$web_port" >/dev/null 2>&1 &
        fi
        WEB_PID=$!; 
        echo -e "${GREEN_C}WEB上传服务已启��?PID: $WEB_PID (端口: $web_port)${NC}"

        if [ -n "$web_pass" ]; then
            echo -e "${GREEN_C}浏览器访��?http://$local_ip:$web_port (账号admin 密码$web_pass)${NC}"
        else
            echo -e "${GREEN_C}浏览器访��?http://$local_ip:$web_port ${NC}"
        fi
        
    else
        # 关闭服务
        if [ -n "$WEB_PID" ]; then
            kill $WEB_PID 2>/dev/null
            WEB_PID=""
            WEB_STATUS="${RED_C}未开��?{NC}"
            echo -e "${YELLOW_C}Web上传服务已关闭��?{NC}"
        else
            echo -e "${YELLOW_C}Web上传服务当前未运行��?{NC}"
        fi
    fi
    sleep 2
}

while true; do
    get_status
    clear
    echo -e "${BLUE_C}================================================${NC}"
    echo -e "${BLUE_C}   xxfn-tool v2601021615 |                      ${NC}"
    echo -e "${BLUE_C}   适用设备：FnOS ARM (OEC / OECT 等设��?        ${NC}"
    echo -e "${BLUE_C}   核心功能：三系统切换、系统升级、LED灯、MAC修改  ${NC}"
    echo -e "${BLUE_C}   脚本工具无任何依赖，干净纯净，可放心使用        ${NC}"
    echo -e "${BLUE_C}================================================${NC}"
    echo -e " 当前运行: ${GREEN_C}$CURRENT_ENV${NC}"
    
    if [ "$CURRENT_ENV" != "$NEXT_BOOT" ]; then
        echo -e " 下次启动: ${YELLOW_C}$NEXT_BOOT (待重��?${NC}"
    else
        echo -e " 下次启动: ${CYAN_C}$NEXT_BOOT${NC}"
    fi

    echo -e " 镜像目录: ${CYAN_C}$IMG_DIR${NC}"
    echo -e "${BLUE_C}------------------------------------------------${NC}"
    echo -e " 飞牛固件最新版��? ${GREEN_C}258${NC}"
    echo -e "${YELLOW_C} 飞牛固件/fpk应用发布页，问题反馈: https://us1.vvvvvv.de5.net/soft${NC}"
    #echo -e "${YELLOW_C}遇到问题的可以加群https://us1.vvvvvv.de5.net/img/qun.jpg${NC}"
    echo -e "${BLUE_C}------------------------------------------------${NC}"
    echo -e "注意: 切换引导需要目标硬盘分区已经安装好了系��?
    echo -e "刷机方式：首次使用请先执��?初始化[分区]再执��?升级刷入新镜��?根据提示上传镜像.img)"
    echo -e "${BLUE_C}------------------------------------------------${NC}"
    echo -e "  1. 切换引导：从 [SATA 硬盘] 启动 |  4. 升级 刷入镜像��?[SATA 硬盘 sdb1]"
    echo -e "  2. 切换引导：从 [eMMC 内置] 启动 |  5. 升级 刷入镜像��?[eMMC 内置 mmcblk0p2]"
    echo -e "  3. 切换引导：从 [USB  硬盘] 启动 |  6. 升级 刷入镜像��?[USB  硬盘 sda1]"
    echo -e "  提示. USB启动有个别设备无法启动，慎用，用USB先lsblk命令查看USB设备确保是sdb"
    echo -e "${BLUE_C}------------------------------------------------${NC}"
    echo -e "  7. 初始化[分区] SATA 硬盘       |  8. 初始化[分区] USB 硬盘"
    echo -e "------------------------------------------------"
    echo -e "  9. LED 灯效管理                 |  10. 修改 MAC 地址"
    echo -e "------------------------------------------------"
    echo -e "克隆方式：直接克隆磁盘方式，先执��?��?分区，再执行13��?4克隆"
    echo -e "------------------------------------------------"
    echo -e "  13. 克隆 eMMC系统 ��?[SATA硬盘 sdb1]|  14. 克隆 eMMC系统 ��?[USB硬盘 sda1]"
    echo -e "  15. 克隆 当前[$CURRENT_ENV] ��?[eMMC内置系统 mmcblk0p2]  "
    echo -e "------------------------------------------------"
    echo -e "  WEB文件上传: $WEB_STATUS"
    echo -e "  16. 开��?Web 上传               |  17. 关闭 Web 上传"
    echo -e "${BLUE_C}------------------------------------------------${NC}"
    echo -e "  11. 重启设备                    |  12. 退出脚��?
    echo -e "${BLUE_C}------------------------------------------------${NC}"
    read -p " 请输入数字选择功能 [1-16]: " choice
    case $choice in
        1) 
            check_system_exists "/dev/sdb1" "SATA 硬盘"
            if [ $? -eq 0 ]; then
                # 优化点：使用正则表达式精准替��?append 行中��?root 参数，支��?/dev/ ��?UUID 格式
                sed -i '/^[[:space:]]*append/s|root=[^[:space:]]*|root=/dev/sdb1|' $BOOT_CONF
                # 校验是否修改成功
                if grep -q "root=/dev/sdb1" "$BOOT_CONF"; then
                    sync && ask_reboot 
                else
                    echo -e "${RED_C}错误: 引导配置文件修改失败，请检查文件权限！${NC}"
                    read -p "按回车返��?.." t
                fi
            else
                read -p "按回车返回菜��?.." t
            fi
            ;;
        2) 
            check_system_exists "/dev/mmcblk0p2" "eMMC 内置"
            if [ $? -eq 0 ]; then
                sed -i '/^[[:space:]]*append/s|root=[^[:space:]]*|root=/dev/mmcblk0p2|' $BOOT_CONF
                # 校验是否修改成功
                if grep -q "root=/dev/mmcblk0p2" "$BOOT_CONF"; then
                    sync && ask_reboot 
                else
                    echo -e "${RED_C}错误: 引导配置文件修改失败，请检查文件权限！${NC}"
                    read -p "按回车返��?.." t
                fi
            else
                read -p "按回车返回菜��?.." t
            fi
            ;;
        3) 
            check_system_exists "/dev/sda1" "USB 硬盘"
            if [ $? -eq 0 ]; then
                sed -i '/^[[:space:]]*append/s|root=[^[:space:]]*|root=/dev/sda1|' $BOOT_CONF
                # 校验是否修改成功
                if grep -q "root=/dev/sda1" "$BOOT_CONF"; then
                    sync && ask_reboot 
                else
                    echo -e "${RED_C}错误: 引导配置文件修改失败，请检查文件权限！${NC}"
                    read -p "按回车返��?.." t
                fi
            else
                read -p "按回车返回菜��?.." t
            fi
            ;;
        4) upgrade_logic "/dev/sdb1" "SATA 硬盘" "SATA" ;;
        5) upgrade_logic "/dev/mmcblk0p2" "eMMC 内置" "EMMC" ;;
        6) upgrade_logic "/dev/sda1" "USB 硬盘" "USB" ;;
        7) init_disk "/dev/sda" "SATA 硬盘" ;;
        8) init_disk "/dev/sdb" "USB 硬盘" ;;
        9) init_led_service; 
           echo -e "\n${CYAN_C}--- LED 灯效控制 ---${NC}"
           echo -e "0:全灭 1:��?2:��?3:��?4:��?5:��?6:��?7:��?11:跑马��?{NC}"
           read -p "请输入颜色编��? " lm
           case $lm in
               11) 
                   echo -e "${YELLOW_C}跑马灯已开启，��?Ctrl+C 立即停止...${NC}"
                   (
                       trap "set_led 0 1 1; exit" SIGINT SIGTERM
                       while true; do
                           for c in "1 0 0" "0 1 0" "0 0 1"; do
                               set_led $c
                               sleep 0.4
                           done
                       done
                   ) & 
                   led_pid=$!
                   trap "kill $led_pid 2>/dev/null; trap - SIGINT; return" SIGINT
                   wait $led_pid 2>/dev/null
                   init_led_service >/dev/null 2>&1
                   echo -e "\n${GREEN_C}>>> 跑马灯已停止��?{NC}"
                   sleep 1
                   ;;
               *) 
                   vals=$(echo $lm | sed 's/0/0 0 0/;s/1/1 0 0/;s/2/0 1 0/;s/3/0 0 1/;s/4/1 1 0/;s/5/1 0 1/;s/6/0 1 1/;s/7/1 1 1/')
                   set_led $vals
                   echo "$vals" > "$LED_CONF"
                   echo -e "${GREEN_C}灯效保存成功��?{NC}"
                   sleep 1 
                   ;;
           esac ;;
        10) mac_manager ;;
        11) sync; reboot ;;
        12) exit 0 ;;
        13) clone_system "/dev/sdb1" "SATA 硬盘" ;;
        14) clone_system "/dev/sda1" "USB 硬盘" ;;
        15) clone_system "/dev/mmcblk0p2" "eMMC 内置" ;;
        16) web_upload_toggle "on" ;;
        17) web_upload_toggle "off" ;;
        *) echo "无效选择"; sleep 1 ;;
    esac
done
# aminsire@qq.com
