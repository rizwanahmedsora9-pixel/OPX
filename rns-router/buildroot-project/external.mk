include $(sort $(wildcard $(BR2_EXTERNAL_RNS_ROUTER_PATH)/package/*/*.mk))
source "$BR2_EXTERNAL_RNS_ROUTER_PATH/package/rns/Config.in"
source "$BR2_EXTERNAL_RNS_ROUTER_PATH/package/extlinux-target/Config.in"
