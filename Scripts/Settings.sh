#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#移除luci-app-attendedsysupgrade
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "/attendedsysupgrade/d" {} +
#修改默认主题
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" {} +
#修改immortalwrt.lan关联IP
find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" -exec sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" {} +
#固件版本行只显示自定义版本号（不再拼接 LuCI 版本号与编译日期）
find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" -exec sed -i "s|_('Firmware Version'),.*|_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description : ''),|" {} +
#修改内核版本号（LuCI 状态-概览里显示的"内核版本"，仅改显示，uname -r 仍为真实内核）
KERNEL_DISPLAY="6.6.6.6"
find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" -exec sed -i "s|_('Kernel Version'),.*|_('Kernel Version'),   '$KERNEL_DISPLAY',|" {} +
#修改固件版本号（LuCI 状态-概览里显示的"固件版本"，取自 board.release.description=os-release 的 OPENWRT_RELEASE）
FW_VERSION="openwrt"
for FW_FILE in ./package/base-files/files/etc/openwrt_release ./package/base-files/files/usr/lib/os-release; do
	[ -f "$FW_FILE" ] || continue
	sed -i "s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION='$FW_VERSION'/" "$FW_FILE"
	sed -i "s/^PRETTY_NAME=.*/PRETTY_NAME=\"$FW_VERSION\"/" "$FW_FILE"
	sed -i "s/^OPENWRT_RELEASE=.*/OPENWRT_RELEASE=\"$FW_VERSION\"/" "$FW_FILE"
done

WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_UC" ]; then
	#修改WIFI名称（用 | 作分隔符，SSID 里含 / 也不会破坏 sed）
	sed -i "s|ssid='.*'|ssid='$WRT_SSID'|g" $WIFI_UC
	#修改WIFI密码
	sed -i "s|key='.*'|key='$WRT_WORD'|g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
[ -f "$CFG_FILE" ] || { echo "ERROR: $CFG_FILE not found"; exit 1; }
#修改默认IP地址（immortalwrt 的 LAN 默认网段是 10.10.10.1，不是 192.168.x.x，需单独替换）
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
sed -i "/lan) ipad=/s/\"[0-9.]*\"/\"$WRT_IP\"/" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#默认启用IPv6（odhcpd 负责 RA 与 DHCPv6）
#注意：odhcpd 自带的 /etc/uci-defaults/15_odhcpd 在首次启动时会把 dhcp.lan.dhcpv6 写回 disabled，
#直接改 feeds 里的 dhcp.conf 模板会被它覆盖，所以这里放一个编号更大的脚本，在它之后执行。
UCI_DEF_DIR="./package/base-files/files/etc/uci-defaults"
mkdir -p "$UCI_DEF_DIR"
cat > "$UCI_DEF_DIR/99-custom-ipv6" <<'EOF'
#!/bin/sh
# LP: 默认开启 IPv6。RA 负责 SLAAC 地址，DHCPv6 负责下发地址与 DNS。
[ -e /proc/sys/net/ipv6 ] || exit 0

uci -q set dhcp.lan.ra='server'
uci -q set dhcp.lan.ra_slaac='1'
uci -q set dhcp.lan.dhcpv6='server'
uci -q commit dhcp
exit 0
EOF
chmod +x "$UCI_DEF_DIR/99-custom-ipv6"

#默认启用UPnP（含IPv6 pinhole）
UPNP_CONF="./feeds/packages/net/miniupnpd/files/upnpd.config"
if [ -f "$UPNP_CONF" ]; then
	sed -i "s/option enabled\t*0/option enabled\t\t1/; s/option ipv6_disable\t*1/option ipv6_disable\t0/" "$UPNP_CONF"
fi

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
#主题自带的配置插件存在时才启用（如 aurora-config；carbon 没有）
if [ -d "./package/luci-app-$WRT_THEME-config" ] || [ -d "./feeds/luci/applications/luci-app-$WRT_THEME-config" ]; then
	echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config
fi

#引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#无WIFI配置调整Q6大小
	if [[ "$WRT_WIFI" == "WIFI-NO" ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
fi

#关键设置自检
#上游一旦重命名文件或改写这几行，上面的 sed 会静默失效，编出来的固件看着正常但设置全丢。
#这里逐项确认修改真的落地，任何一项没生效就让编译直接失败。
SELF_CHECK_FAILED=0
check_setting() {
	local DESC=$1
	shift
	if "$@"; then
		echo "[check] OK   $DESC"
	else
		echo "[check] FAIL $DESC"
		SELF_CHECK_FAILED=1
	fi
}

SYS_JS=$(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" | head -1)
if [ -z "$SYS_JS" ]; then
	echo "[check] FAIL 找不到 10_system.js，LuCI 状态页可能已改结构"
	SELF_CHECK_FAILED=1
	SYS_JS=/dev/null
fi
check_setting "内核版本显示 $KERNEL_DISPLAY" \
	grep -qF "'$KERNEL_DISPLAY'," "$SYS_JS"
check_setting "固件版本行不拼接 LuCI 版本" \
	grep -qF "_('Firmware Version'), (L.isObject(boardinfo.release)" "$SYS_JS"
check_setting "固件版本号 $FW_VERSION" \
	grep -qF "DISTRIB_DESCRIPTION='$FW_VERSION'" ./package/base-files/files/etc/openwrt_release
check_setting "默认 IP $WRT_IP" \
	grep -qF "\"$WRT_IP\"" "$CFG_FILE"
check_setting "默认主机名 $WRT_NAME" \
	grep -qF "hostname='$WRT_NAME'" "$CFG_FILE"
check_setting "IPv6 uci-defaults 脚本可执行" \
	test -x "$UCI_DEF_DIR/99-custom-ipv6"
check_setting "默认主题 $WRT_THEME 已替换 bootstrap" \
	bash -c "! grep -rq --include=Makefile 'luci-theme-bootstrap' ./feeds/luci/collections/"
check_setting "默认主题 $WRT_THEME 已加入 collections" \
	grep -rq --include=Makefile "luci-theme-$WRT_THEME" ./feeds/luci/collections/

if [ -f "$WIFI_UC" ]; then
	check_setting "WIFI 名称 $WRT_SSID" \
		grep -qF "ssid='$WRT_SSID'" "$WIFI_UC"
else
	echo "[check] WARN $WIFI_UC 不存在，WIFI 名称/密码未修改"
fi

if [ -f "$UPNP_CONF" ]; then
	check_setting "UPnP 默认启用" \
		grep -qP 'option enabled\s+1' "$UPNP_CONF"
else
	echo "[check] WARN $UPNP_CONF 不存在，UPnP 默认值未修改"
fi

if [ "$SELF_CHECK_FAILED" -ne 0 ]; then
	echo "ERROR: 关键设置未生效，见上面 [check] FAIL 行。上游文件结构可能已变化，请更新 Scripts/Settings.sh。"
	exit 1
fi
echo "all settings verified"
