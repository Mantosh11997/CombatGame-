import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';

// Collapses many small meshes into a few vertex-colored ones, so a model costs
// a handful of draw calls instead of dozens. Each part keeps its material's
// color as per-vertex color under one shared material.

function coloredGeometry(mesh, matrix) {
  const g = (mesh.geometry.index ? mesh.geometry.toNonIndexed() : mesh.geometry.clone());
  for (const key of Object.keys(g.attributes)) {
    if (key !== 'position' && key !== 'normal' && key !== 'color') g.deleteAttribute(key);
  }
  g.applyMatrix4(matrix);
  if (!g.attributes.color) {
    // Material colors are linear in three.js, which is what glTF COLOR_0 wants.
    const c = mesh.material.color ?? new THREE.Color(1, 1, 1);
    const colors = new Float32Array(g.attributes.position.count * 3);
    for (let i = 0; i < colors.length; i += 3) colors.set([c.r, c.g, c.b], i);
    g.setAttribute('color', new THREE.BufferAttribute(colors, 3));
  }
  return g;
}

export function bakedMaterial(name = 'Baked', { roughness = 0.75, metalness = 0 } = {}) {
  return new THREE.MeshStandardMaterial({ name, vertexColors: true, roughness, metalness });
}

/**
 * Merges every mesh under [root] into one mesh (child of root), keeping
 * non-mesh nodes (markers like Muzzle) and any subtree whose name matches
 * [keep] (e.g. propellers that must spin on their own).
 */
export function bakeAll(root, material, keep = null) {
  root.updateMatrixWorld(true);
  const inverse = root.matrixWorld.clone().invert();
  const parts = [];
  const doomed = [];
  root.traverse((o) => {
    if (o === root || !o.isMesh) return;
    for (let p = o.parent; p && p !== root; p = p.parent) if (keep?.test(p.name)) return;
    parts.push(coloredGeometry(o, inverse.clone().multiply(o.matrixWorld)));
    doomed.push(o);
  });
  for (const o of doomed) o.removeFromParent();
  const mesh = new THREE.Mesh(mergeGeometries(parts), material);
  mesh.name = `${root.name}Mesh`;
  mesh.castShadow = true;
  root.add(mesh);
  return root;
}

/**
 * For an articulated model: merges the meshes directly under each joint into
 * one mesh per joint, so the joints still animate independently.
 */
export function bakeByJoint(root, material) {
  const joints = [];
  root.traverse((o) => {
    if (o.children.some((c) => c.isMesh)) joints.push(o);
  });
  for (const j of joints) {
    const meshes = j.children.filter((c) => c.isMesh);
    const parts = meshes.map((m) => {
      m.updateMatrix();
      return coloredGeometry(m, m.matrix);
    });
    for (const m of meshes) m.removeFromParent();
    const mesh = new THREE.Mesh(mergeGeometries(parts), material);
    mesh.name = `${j.name}Mesh`;
    mesh.castShadow = true;
    j.add(mesh);
  }
  return root;
}
