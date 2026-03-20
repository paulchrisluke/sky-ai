#!/bin/bash

# Test script for Sky AI API
API_URL="${SKY_AI_API_URL:-https://sky-ai-api.paulchrisluke.workers.dev}"
API_KEY="${SKY_AI_API_KEY}"

if [ -z "$API_KEY" ]; then
    echo "Error: SKY_AI_API_KEY environment variable is required"
    echo "Usage: SKY_AI_API_KEY=your_key ./test_api.sh"
    exit 1
fi

echo "Testing Sky AI API..."
echo "URL: $API_URL"
echo "API Key: ${API_KEY:0:10}..."

# Test health endpoint
echo -e "\n1. Testing health endpoint:"
HEALTH_RESPONSE=$(curl -s -w "%{http_code}" "$API_URL/health" -H "Authorization: Bearer $API_KEY" -o /tmp/health_response.json)
echo "HTTP Status: $HEALTH_RESPONSE"
if [ -f /tmp/health_response.json ]; then
    echo "Response: $(cat /tmp/health_response.json)"
fi

# Test search endpoint
echo -e "\n2. Testing search endpoint:"
SEARCH_RESPONSE=$(curl -s -w "%{http_code}" "$API_URL/search" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d '{"workspaceId":"default","accountId":"paulchrisluke@gmail.com","query":"Southwest Airlines","k":5}' \
    -o /tmp/search_response.json)
echo "HTTP Status: $SEARCH_RESPONSE"
if [ -f /tmp/search_response.json ]; then
    echo "Response: $(cat /tmp/search_response.json)"
fi

# Test chat query endpoint
echo -e "\n3. Testing chat query endpoint:"
CHAT_RESPONSE=$(curl -s -w "%{http_code}" "$API_URL/chat/query" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d '{"workspaceId":"default","accountId":"paulchrisluke@gmail.com","query":"Show me my flight reservations","sessionId":"test-123"}' \
    -o /tmp/chat_response.json)
echo "HTTP Status: $CHAT_RESPONSE"
if [ -f /tmp/chat_response.json ]; then
    echo "Response: $(cat /tmp/chat_response.json)"
fi

# Cleanup
rm -f /tmp/health_response.json /tmp/search_response.json /tmp/chat_response.json
