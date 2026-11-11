#!/bin/bash
# Assets OTA Patch for xiaozhi-esp32-server
# This script applies all modifications needed for assets OTA online push.
# Run inside the Docker container: docker exec -it xiaozhi-esp32-server bash /path/to/apply_assets_ota_patch.sh

set -e
BASE="/opt/xiaozhi-esp32-server"

echo "=== Applying Assets OTA Patch ==="

# 1. Patch ota_handler.py
# Add ws_server parameter to __init__
sed -i 's/def __init__(self, config: dict):/def __init__(self, config: dict, ws_server=None):/' $BASE/core/api/ota_handler.py
# Add ws_server and assets_dir attributes after super().__init__
sed -i '/super().__init__(config)/a\        self.ws_server = ws_server
        self.assets_dir = os.path.join(os.getcwd(), "data", "assets")' $BASE/core/api/ota_handler.py

# Add assets URL to OTA POST response
# Insert after the firmware block in return_json
python3 -c "
import re
with open('$BASE/core/api/ota_handler.py', 'r') as f:
    content = f.read()
# Add assets URL check after return_json construction
old = '"url": "",\n                },\n            }'
new = '"url": "",\n                },\n            }\n\n            # Check for assets update\n            assets_url = self._get_assets_url()\n            if assets_url:\n                return_json["assets"] = {"url": assets_url}'
content = content.replace(old, new, 1)
with open('$BASE/core/api/ota_handler.py', 'w') as f:
    f.write(content)
"

# Append new handler methods
cat >> $BASE/core/api/ota_handler.py << 'METHODS_EOF'

    def _get_assets_url(self):
        try:
            if not os.path.isdir(self.assets_dir):
                return None
            bin_files = glob.glob(os.path.join(self.assets_dir, "*.bin"))
            if not bin_files:
                return None
            bin_file = max(bin_files, key=os.path.getmtime)
            fname = os.path.basename(bin_file)
            local_ip = get_local_ip()
            port = int(self.config["server"].get("http_port", 8003))
            return f"http://{local_ip}:{port}/xiaozhi/download/assets/{fname}"
        except Exception as e:
            self.logger.bind(tag=TAG).error(f"Error getting assets URL: {e}")
            return None

    async def handle_assets_page(self, request):
        try:
            page_path = os.path.join(os.getcwd(), "data", "assets_page.html")
            if os.path.exists(page_path):
                with open(page_path, "r", encoding="utf-8") as f:
                    html = f.read()
                return web.Response(text=html, content_type="text/html")
            return web.Response(text="<h1>Assets Page Not Found</h1>", status=404)
        except Exception as e:
            self.logger.bind(tag=TAG).error(f"Error serving assets page: {e}")
            return web.Response(text=f"Error: {e}", status=500)

    async def handle_assets_upload(self, request):
        try:
            reader = await request.multipart()
            field = await reader.next()
            if field.name == "file":
                filename = field.filename or "assets.bin"
                filename = _safe_basename(filename)
                if not os.path.isdir(self.assets_dir):
                    os.makedirs(self.assets_dir, exist_ok=True)
                filepath = os.path.join(self.assets_dir, filename)
                with open(filepath, "wb") as f:
                    while True:
                        chunk = await field.read_chunk()
                        if not chunk:
                            break
                        f.write(chunk)
                self.logger.bind(tag=TAG).info(f"Assets uploaded: {filename}")
                return web.json_response({"success": True, "filename": filename})
            return web.json_response({"success": False, "error": "No file field"}, status=400)
        except Exception as e:
            self.logger.bind(tag=TAG).error(f"Assets upload error: {e}")
            return web.json_response({"success": False, "error": str(e)}, status=500)

    async def handle_assets_push(self, request):
        try:
            data = await request.json()
            device_id = data.get("device_id", "")
            if not device_id:
                return web.json_response({"success": False, "error": "device_id required"}, status=400)
            assets_url = self._get_assets_url()
            if not assets_url:
                return web.json_response({"success": False, "error": "No assets file found"}, status=404)
            if self.ws_server:
                message = {"type": "system", "command": "update_assets", "url": assets_url}
                sent = self.ws_server.send_to_device(device_id, message)
                if sent:
                    self.logger.bind(tag=TAG).info(f"Assets push sent to device {device_id}")
                    return web.json_response({"success": True, "device_id": device_id})
                else:
                    return web.json_response({"success": False, "error": "Device not online"}, status=404)
            else:
                return web.json_response({"success": False, "error": "WebSocket server not available"}, status=500)
        except Exception as e:
            self.logger.bind(tag=TAG).error(f"Assets push error: {e}")
            return web.json_response({"success": False, "error": str(e)}, status=500)

    async def handle_assets_list(self, request):
        try:
            files = []
            if os.path.isdir(self.assets_dir):
                for fname in os.listdir(self.assets_dir):
                    if fname.endswith(".bin"):
                        fpath = os.path.join(self.assets_dir, fname)
                        files.append({"filename": fname, "size": os.path.getsize(fpath)})
            online_devices = []
            if self.ws_server:
                online_devices = self.ws_server.get_online_devices()
            return web.json_response({"files": files, "online_devices": online_devices})
        except Exception as e:
            self.logger.bind(tag=TAG).error(f"Assets list error: {e}")
            return web.json_response({"files": [], "online_devices": [], "error": str(e)})

    async def handle_assets_download(self, request):
        try:
            filename = request.match_info.get("filename", "")
            filename = _safe_basename(filename)
            filepath = os.path.join(self.assets_dir, filename)
            if os.path.exists(filepath):
                return web.FileResponse(filepath)
            return web.Response(text="File not found", status=404)
        except Exception as e:
            self.logger.bind(tag=TAG).error(f"Assets download error: {e}")
            return web.Response(text=f"Error: {e}", status=500)
METHODS_EOF

# 2. Patch websocket_server.py
# Add active_connections dict
sed -i '/self.config_lock = asyncio.Lock()/a\        self.active_connections = {}  # device_id -> ConnectionHandler' $BASE/core/websocket_server.py

# Add register/unregister in _handle_connection
sed -i '/await handler.handle_connection(websocket)/i\        device_id = headers.get("device-id", "")
        if device_id:
            self.active_connections[device_id] = handler' $BASE/core/websocket_server.py

# Add unregister in finally block
sed -i '/finally:/a\            if device_id and device_id in self.active_connections:
                del self.active_connections[device_id]' $BASE/core/websocket_server.py

# Append send_to_device and get_online_devices methods
cat >> $BASE/core/websocket_server.py << 'WS_METHODS_EOF'

    def send_to_device(self, device_id: str, message: dict) -> bool:
        handler = self.active_connections.get(device_id)
        if handler and hasattr(handler, 'websocket') and handler.websocket:
            try:
                import json
                handler.websocket.send(json.dumps(message))
                return True
            except Exception as e:
                self.logger.bind(tag=TAG).error(f"Error sending to device {device_id}: {e}")
                return False
        return False

    def get_online_devices(self) -> list:
        return list(self.active_connections.keys())
WS_METHODS_EOF

echo "=== Patch applied successfully ==="
echo "Restart the container: docker restart xiaozhi-esp32-server"
