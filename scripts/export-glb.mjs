// Builds every asset in Node and writes binary glTF files to game/assets/models/.
// Usage: npm run export            (all assets)
//        npm run export -- soldier (only the named ones)
import { mkdir, writeFile } from 'node:fs/promises';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { ASSETS, buildAsset, createMaterials } from '../src/assets/index.js';

// GLTFExporter reads Blobs through FileReader, which Node does not provide.
globalThis.FileReader ??= class {
  readAsArrayBuffer(blob) {
    blob.arrayBuffer().then((buf) => { this.result = buf; this.onloadend?.(); });
  }
  readAsDataURL(blob) {
    blob.arrayBuffer().then((buf) => {
      this.result = `data:${blob.type};base64,${Buffer.from(buf).toString('base64')}`;
      this.onloadend?.();
    });
  }
};

// Written straight into the Flutter game's assets, where its build hook
// converts each .glb to the engine's fast-loading format.
const outDir = new URL('../game/assets/models/', import.meta.url);
await mkdir(outDir, { recursive: true });

const wanted = process.argv.slice(2);
const keys = wanted.length ? wanted : Object.keys(ASSETS);
const exporter = new GLTFExporter();
const mats = createMaterials();

for (const key of keys) {
  if (!ASSETS[key]) {
    console.error(`Unknown asset "${key}". Available: ${Object.keys(ASSETS).join(', ')}`);
    process.exitCode = 1;
    continue;
  }
  const object = buildAsset(key, mats);
  object.updateMatrixWorld(true);
  const glb = await exporter.parseAsync(object, { binary: true, animations: object.animations ?? [] });
  const file = new URL(`${key}.glb`, outDir);
  await writeFile(file, Buffer.from(glb));
  let meshes = 0, triangles = 0;
  object.traverse((o) => {
    if (!o.isMesh) return;
    meshes++;
    const g = o.geometry;
    triangles += (g.index ? g.index.count : g.attributes.position.count) / 3;
  });
  if (object.collision) {
    // Gameplay collision data for the game (heightfield + colliders).
    await writeFile(new URL(`${key}.collision.json`, outDir), JSON.stringify(object.collision));
  }
  console.log(`${key.padEnd(16)} ${(glb.byteLength / 1024).toFixed(0).padStart(6)} KB  ${String(meshes).padStart(4)} meshes  ${Math.round(triangles).toString().padStart(7)} tris  ${(object.animations ?? []).length} anims`);
}
