#!/usr/bin/env python3
"""
SMRITI Local HTTP API Server.
Exposes SMRITI memory functions via simple HTTP REST endpoints on localhost:7798.
"""

import sys
import os
import json
import signal
import threading
import logging
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

# Setup logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("smriti_api")

try:
    from smriti_memcore.core import SMRITI
    from smriti_memcore.models import MemorySource, Modality
except ImportError:
    logger.error("smriti-memcore package is not installed. Run 'pip install smriti-memcore'.")
    sys.exit(1)

# Global variables
smriti_instance = None
httpd = None
last_palace_mtime = 0

def check_and_reload_palace():
    global smriti_instance, last_palace_mtime
    if not smriti_instance:
        return
    palace_file = os.path.join(smriti_instance.config.storage_path, "palace", "palace.json")
    if not os.path.exists(palace_file):
        return
    
    try:
        mtime = os.path.getmtime(palace_file)
        if last_palace_mtime == 0:
            last_palace_mtime = mtime
            return
            
        if mtime > last_palace_mtime:
            logger.info("Shared palace updated on disk by another process. Reloading state...")
            from smriti_memcore.models import SmritiConfig
            config = SmritiConfig(storage_path=smriti_instance.config.storage_path)
            
            # Preserve the warmed embedding model
            old_model = smriti_instance.vector_store._model
            
            # Recreate instance
            new_instance = SMRITI(config=config)
            new_instance.vector_store._model = old_model
            
            smriti_instance = new_instance
            last_palace_mtime = mtime
            logger.info(f"Palace reloaded. Count: {len(smriti_instance.palace.memories)}")
    except Exception as e:
        logger.error(f"Failed to check/reload palace: {e}")

class SMRITIHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Suppress standard logging to prevent console pollution
        pass

    def _send_response(self, status_code, data):
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode("utf-8"))

    def do_OPTIONS(self):
        self._send_response(200, {"status": "ok"})

    def do_GET(self):
        check_and_reload_palace()
        if self.path == "/health":
            # Check if smriti is initialized and return stats
            try:
                mem_count = len(smriti_instance.palace.memories)
                self._send_response(200, {
                    "status": "ok",
                    "memories_count": mem_count,
                    "storage_path": smriti_instance.config.storage_path
                })
            except Exception as e:
                self._send_response(500, {"error": f"Failed to get stats: {e}"})
        else:
            self._send_response(404, {"error": "Endpoint not found"})

    def do_POST(self):
        check_and_reload_palace()
        content_length = int(self.headers.get("Content-Length", 0))
        post_data = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else ""

        try:
            req_data = json.loads(post_data) if post_data else {}
        except json.JSONDecodeError:
            self._send_response(400, {"error": "Invalid JSON"})
            return

        if self.path == "/recall":
            query = req_data.get("query", "")
            top_k = int(req_data.get("top_k", 5))

            if not query:
                self._send_response(400, {"error": "Missing 'query' parameter"})
                return

            try:
                memories = smriti_instance.recall(query, top_k=top_k)
                serialized = []
                for mem in memories:
                    serialized.append({
                        "id": mem.id,
                        "content": mem.content,
                        "strength": mem.strength,
                        "room": mem.room_id,
                        "source": mem.source.value,
                        "created": mem.creation_time.isoformat()
                    })
                self._send_response(200, {"memories": serialized})
            except Exception as e:
                logger.exception("Recall failed")
                self._send_response(500, {"error": str(e)})

        elif self.path == "/encode":
            content = req_data.get("content", "")
            source_str = req_data.get("source", "direct")
            modality_str = req_data.get("modality", "text")
            use_llm = req_data.get("use_llm", False)

            if not content:
                self._send_response(400, {"error": "Missing 'content' parameter"})
                return

            try:
                try:
                    source = MemorySource(source_str)
                except ValueError:
                    source = MemorySource.DIRECT
                try:
                    modality = Modality(modality_str)
                except ValueError:
                    modality = Modality.TEXT

                # Run encode
                memory_id = smriti_instance.encode(
                    content,
                    source=source,
                    modality=modality,
                    use_llm=use_llm
                )
                
                # Make sure to save changes
                smriti_instance.save()

                if memory_id:
                    self._send_response(200, {"status": "encoded", "memory_id": memory_id})
                else:
                    self._send_response(200, {"status": "discarded", "memory_id": None})
            except Exception as e:
                logger.exception("Encode failed")
                self._send_response(500, {"error": str(e)})

        elif self.path == "/consolidate":
            try:
                logger.info("Running manual consolidation...")
                smriti_instance.consolidate(depth="light")
                smriti_instance.save()
                self._send_response(200, {"status": "success", "summary": "Light consolidation completed"})
            except Exception as e:
                logger.exception("Consolidation failed")
                self._send_response(500, {"error": str(e)})
        else:
            self._send_response(404, {"error": "Endpoint not found"})

def shutdown_handler(signum, frame):
    logger.info(f"Received signal {signum}. Initiating shutdown...")
    
    # Run a light consolidation on exit to clean up working slots
    if smriti_instance:
        try:
            logger.info("Running exit memory consolidation...")
            smriti_instance.consolidate(depth="light")
            smriti_instance.save()
            logger.info("Consolidation completed successfully.")
        except Exception as e:
            logger.error(f"Consolidation on exit failed: {e}")
            
    # Stop the server
    if httpd:
        # Must serve in a thread to use shutdown() without blocking,
        # but since we are terminating the process anyway, we can just exit.
        pass
    
    sys.exit(0)

def warmup_model(smriti):
    logger.info("Starting background embedding model pre-load (warmup)...")
    try:
        # Accessing the property triggers lazy model load and downloads/warmup sentence-transformers
        _ = smriti.vector_store.model
        logger.info("Embedding model pre-loaded and ready.")
    except Exception as e:
        logger.warning(f"Embedding model pre-load failed: {e}")

def main():
    global smriti_instance, httpd
    
    # Register termination signals
    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)
    
    # Initialize SMRITI
    logger.info("Initializing SMRITI core...")
    try:
        from smriti_memcore.models import SmritiConfig
        storage_path = os.path.expanduser("~/.smriti/global")
        config = SmritiConfig(storage_path=storage_path)
        smriti_instance = SMRITI(config=config)
    except Exception as e:
        logger.exception("Failed to initialize SMRITI")
        sys.exit(1)
        
    # Warmup embedding model in a separate thread so startup is instant
    threading.Thread(target=warmup_model, args=(smriti_instance,), daemon=True).start()

    # Launch local HTTP server
    port = 7798
    server_address = ("127.0.0.1", port)
    
    try:
        httpd = HTTPServer(server_address, SMRITIHandler)
        logger.info(f"SMRITI local API listening on http://127.0.0.1:{port}")
        httpd.serve_forever()
    except Exception as e:
        logger.exception(f"HTTP Server failed on port {port}")
        sys.exit(1)

if __name__ == "__main__":
    main()
