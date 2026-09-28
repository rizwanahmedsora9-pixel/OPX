################################################################################
#
# extlinux-target
#
# Buildroot's boot/syslinux package builds the syslinux installer tools with
# the *host* toolchain (patches 0004/0005/0011 redirect utils/, lzo/ and
# extlinux/ to CC_FOR_BUILD), because they are normally run on the build
# machine. OPX needs the 'extlinux' installer to run *inside the live system*
# at install time, so this package builds the same syslinux 6.03 sources once
# more with the target toolchain and installs the resulting tool into the
# rootfs at /usr/sbin/extlinux.
#
# Same sources, same download location and same patch set as boot/syslinux
# (minus the three host-toolchain redirects), so the tarball is shared with
# the buildroot package's dl/ cache entry.
#
################################################################################

EXTLINUX_TARGET_VERSION = 6.03
EXTLINUX_TARGET_SOURCE = syslinux-$(EXTLINUX_TARGET_VERSION).tar.xz
EXTLINUX_TARGET_SITE = $(BR2_KERNEL_MIRROR)/linux/utils/boot/syslinux
EXTLINUX_TARGET_LICENSE = GPL-2.0+
EXTLINUX_TARGET_LICENSE_FILES = COPYING
EXTLINUX_TARGET_DEPENDENCIES = \
	host-nasm \
	host-python3 \
	host-upx \
	host-util-linux \
	util-linux

# 'make bios' builds core, com32, mbr, memdisk and the installer tools.
# Everything is compiled with the target toolchain; the extlinux binary
# therefore runs inside the target (that is the point of this package).
define EXTLINUX_TARGET_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE1) \
		ASCIIDOC_OK=-1 \
		A2X_XML_OK=-1 \
		CC="$(TARGET_CC)" \
		LD="$(TARGET_LD)" \
		OBJCOPY="$(TARGET_OBJCOPY)" \
		AS="$(TARGET_AS)" \
		NASM="$(HOST_DIR)/bin/nasm" \
		PYTHON=$(HOST_DIR)/bin/python3 \
		-C $(@D) bios
endef

define EXTLINUX_TARGET_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/bios/extlinux/extlinux \
		$(TARGET_DIR)/usr/sbin/extlinux
endef

$(eval $(generic-package))
