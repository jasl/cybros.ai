"""Keep an isolated transport world alive for the public Nexus lifecycle probe."""
import json
import sys
from bench import World

world = World()
world.refresh = False
try:
    world.start()
    print(json.dumps({'urls': world.urls, 'connection': world.connect('auto')}), flush=True)
    sys.stdin.readline()
finally:
    world.close()
