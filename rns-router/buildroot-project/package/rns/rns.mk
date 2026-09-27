################################################################################
# rns
################################################################################

RNS_VERSION = 1.0
RNS_SITE = $(BR2_EXTERNAL_RNS_ROUTER_PATH)/package/rns
RNS_SITE_METHOD = local
RNS_LICENSE = Proprietary

define RNS_INSTALL_TARGET_CMDS
	$(INSTALL) -d $(TARGET_DIR)/usr/share/rns/bin
	$(INSTALL) -d $(TARGET_DIR)/usr/share/rns/www
	cp -f $(BR2_EXTERNAL_RNS_ROUTER_PATH)/board/rns/x86_64/rootfs-overlay/usr/share/rns/bin/* \
		$(TARGET_DIR)/usr/share/rns/bin/ 2>/dev/null || true
	cp -f $(BR2_EXTERNAL_RNS_ROUTER_PATH)/board/rns/x86_64/rootfs-overlay/usr/share/rns/www/* \
		$(TARGET_DIR)/usr/share/rns/www/ 2>/dev/null || true
	chmod 755 $(TARGET_DIR)/usr/share/rns/bin/*.sh 2>/dev/null || true
endef

$(eval $(generic-package))
