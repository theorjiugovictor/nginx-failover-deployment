#!/bin/sh
set -e

# Determine active and backup pools
ACTIVE=${ACTIVE_POOL:-blue}
APP_PORT=${PORT:-3000}

if [ "$ACTIVE" = "blue" ]; then
    BACKUP="green"
else
    BACKUP="blue"
fi

echo "Active pool: $ACTIVE"
echo "Backup pool: $BACKUP"
echo "App port: $APP_PORT"

# Generate nginx config from template
sed -e "s/ACTIVE_POOL/$ACTIVE/g" \
    -e "s/BACKUP_POOL/$BACKUP/g" \
    -e "s/APP_PORT/$APP_PORT/g" \
    /etc/nginx/templates/nginx.conf.template > /etc/nginx/nginx.conf

echo "Nginx configuration generated successfully"
cat /etc/nginx/nginx.conf

# Test the configuration
nginx -t
