#!/bin/bash

# Webhook URL: https://mail.google.com/chat/u/1/#chat/space/AAAAx1oFTbE
WEBHOOK_URL=$GOOGLE_CHAT_WEBHOOK

# Threshold
THRESHOLD=4.0

# Get the current load average (1-minute)
LOAD=$(awk '{print $1}' /proc/loadavg)

# Get the server's hostname
HOSTNAME=$(hostname)

# Check if the load exceeds the threshold
if (($(echo "$LOAD > $THRESHOLD" | bc -l))); then

    # Get `docker stats` in table format
    DOCKER_STATS=$(docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}")

    FORMATTED_STATS="\`\`\`${DOCKER_STATS}\`\`\`"

    # Create the JSON payload for Google Chat
    JSON_PAYLOAD=$(
        jq -n \
            --arg sender "Incoming" \
            --arg text "**WARNING: High Server Load Detected**" \
            --arg load "Load Average: $LOAD" \
            --arg host "$HOSTNAME" \
            --arg stats "$FORMATTED_STATS" \
            '{
                
                "cardsV2": [
                    {   
                        "cardId": "unique-card-id",
                        "card": {
                            "header": {
                                "title": "Server Agent",
                                "subtitle": $host,
                                "imageUrl": "https://developers.google.com/workspace/chat/images/quickstart-app-avatar.png",
                                "imageType": "CIRCLE",
                                "imageAltText": "Agent Avatar"
                            },
                            "sections": [
                                {
                                "collapsible": false,
                                "uncollapsibleWidgetsCount": 1,
                                "widgets": [
                                    {
                                    "chipList": {
                                        "chips": [
                                        {
                                            "label": "High Load Detected",
                                            "icon": {
                                            "materialIcon": {
                                                "name": "warning"
                                            }
                                            }
                                        }
                                        ]
                                    }
                                    },
                                    {
                                    "textParagraph": {
                                        "text": "",
                                        "maxLines": 3
                                    }
                                    },
                                    {
                                    "buttonList": {
                                        "buttons": [
                                            {
                                                "text": "Call Support",
                                                "icon": {
                                                "materialIcon": {
                                                    "name": "call"
                                                }
                                                },
                                                "color": {
                                                "red": 1,
                                                "green": 0,
                                                "blue": 0,
                                                "alpha": 1
                                                },
                                                "type": "FILLED",
                                                "onClick": {
                                                "openLink": {
                                                    "url": "tel:+12149983380"
                                                }
                                                }
                                            }
                                        ]
                                    }
                                    }
                                ]
                                }
                            ]
                        }
                    }
                ],
                "text": $stats,

            }'
    )

    # Send the message to Google Chat
    curl --silent --output /dev/null --show-error --fail -X POST -H "Content-Type: application/json" -d "$JSON_PAYLOAD" "$WEBHOOK_URL"
fi