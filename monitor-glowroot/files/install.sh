#!/bin/bash

echo "configuring cassandra service ..."
systemctl daemon-reload
systemctl enable cassandra
systemctl start cassandra
systemctl status cassandra
echo "cassandra service config finished"

echo "configuring glowroot central app"
mv /opt/glowroot.sh /opt/glowroot-central/glowroot.sh
systemctl enable glowroot
systemctl start glowroot
systemctl status glowroot

echo "Install Finished!"

