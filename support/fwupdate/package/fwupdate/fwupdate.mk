################################################################################
#
# fwupdate
#
################################################################################

FWUPDATE_VERSION = 1.0
FWUPDATE_SITE = package/fwupdate
FWUPDATE_SITE_METHOD = local
FWUPDATE_LICENSE = GPL-2.0-or-later

FWUPDATE_CFLAGS = $(TARGET_CFLAGS) -Os -Wall -Wextra -Werror -std=c99

# The flashing process must not demand-page code or shared libraries from the
# SquashFS partition while that partition is being erased. Build a static,
# stripped helper and copy it to tmpfs before use.
define FWUPDATE_BUILD_CMDS
	$(TARGET_CC) $(FWUPDATE_CFLAGS) -static \
		-o $(@D)/fwflash $(@D)/fwflash.c
	$(TARGET_STRIP) $(@D)/fwflash
endef

define FWUPDATE_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/fwflash \
		$(TARGET_DIR)/usr/libexec/fwupdate/fwflash
	$(INSTALL) -D -m 0644 $(@D)/files/common.sh \
		$(TARGET_DIR)/usr/lib/fwupdate/common.sh
	$(INSTALL) -D -m 0755 $(@D)/files/fw_update \
		$(TARGET_DIR)/bin/fw_update
	$(INSTALL) -D -m 0755 $(@D)/files/fw_update_http \
		$(TARGET_DIR)/bin/fw_update_http
	$(INSTALL) -D -m 0755 $(@D)/files/fw_update_tftp \
		$(TARGET_DIR)/bin/fw_update_tftp
	$(INSTALL) -D -m 0755 $(@D)/files/fw_update_sftp \
		$(TARGET_DIR)/bin/fw_update_sftp
	$(INSTALL) -D -m 0755 $(@D)/files/fw_update_status \
		$(TARGET_DIR)/bin/fw_update_status
	$(INSTALL) -D -m 0644 $(@D)/files/sources.conf \
		$(TARGET_DIR)/etc/fwupdate/sources.conf
	$(INSTALL) -D -m 0644 $(@D)/files/preserve.list \
		$(TARGET_DIR)/etc/fwupdate/preserve.list
endef

$(eval $(generic-package))
