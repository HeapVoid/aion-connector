[Unit]
Description=AION Connector (workspace {{WORKSPACE_SLUG}})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/aion-connector run
Restart=on-failure
RestartSec=5
Environment=HOME={{USER_HOME}}
Environment=AION_EXTERNAL_IP={{EXTERNAL_IP}}

[Install]
WantedBy=default.target
