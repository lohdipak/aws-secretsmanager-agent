#
# Creates the provider user/group and sets directory ownership.
# Sourced by both `install` and RPM %post (rpm_setup.sh).
#

#
# User and group setup
#

groupadd -f "${PROVIDER_GROUP}"
groupadd -f "${TOKEN_GROUP}"
useradd -r -M -d "${PROVIDER_DIR}" -s /sbin/nologin -g "${PROVIDER_GROUP}" -G "${TOKEN_GROUP}" "${PROVIDER_USER}" || [ $? -eq 9 ]

#
# Set ownership on installed files
#

chown "${PROVIDER_USER}:${PROVIDER_GROUP}" "${PROVIDER_DIR}"