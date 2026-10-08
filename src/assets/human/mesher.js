// Turns a signed distance field into a smooth triangle mesh with "surface
// nets": one vertex per surface cell, placed at the average of the cell's
// edge crossings, then projected exactly onto the surface. Normals come from
// the field's gradient, so shading is smooth without seams.

const EDGES = [
  [0, 1], [2, 3], [4, 5], [6, 7],
  [0, 2], [1, 3], [4, 6], [5, 7],
  [0, 4], [1, 5], [2, 6], [3, 7],
];

/**
 * @param field  (p:[x,y,z]) => distance
 * @param min,max  bounding box corners
 * @param step  cell size in meters
 * @returns { positions: Float32Array, normals: Float32Array, indices: Uint32Array }
 */
export function meshField(field, min, max, step) {
  const nx = Math.ceil((max[0] - min[0]) / step) + 1;
  const ny = Math.ceil((max[1] - min[1]) / step) + 1;
  const nz = Math.ceil((max[2] - min[2]) / step) + 1;
  const values = new Float32Array(nx * ny * nz);
  const at = (i, j, k) => (k * ny + j) * nx + i;
  for (let k = 0; k < nz; k++) {
    for (let j = 0; j < ny; j++) {
      for (let i = 0; i < nx; i++) {
        values[at(i, j, k)] = field([min[0] + i * step, min[1] + j * step, min[2] + k * step]);
      }
    }
  }

  // One vertex per cell that the surface passes through.
  const cellVertex = new Int32Array((nx - 1) * (ny - 1) * (nz - 1)).fill(-1);
  const cellAt = (i, j, k) => (k * (ny - 1) + j) * (nx - 1) + i;
  const positions = [];
  const corner = new Float32Array(8);
  for (let k = 0; k < nz - 1; k++) {
    for (let j = 0; j < ny - 1; j++) {
      for (let i = 0; i < nx - 1; i++) {
        let mask = 0;
        for (let c = 0; c < 8; c++) {
          const v = values[at(i + (c & 1), j + ((c >> 1) & 1), k + ((c >> 2) & 1))];
          corner[c] = v;
          if (v < 0) mask |= 1 << c;
        }
        if (mask === 0 || mask === 255) continue;
        let sx = 0, sy = 0, sz = 0, n = 0;
        for (const [a, b] of EDGES) {
          const va = corner[a], vb = corner[b];
          if ((va < 0) === (vb < 0)) continue;
          const t = va / (va - vb);
          sx += (a & 1) + ((b & 1) - (a & 1)) * t;
          sy += ((a >> 1) & 1) + (((b >> 1) & 1) - ((a >> 1) & 1)) * t;
          sz += ((a >> 2) & 1) + (((b >> 2) & 1) - ((a >> 2) & 1)) * t;
          n++;
        }
        cellVertex[cellAt(i, j, k)] = positions.length / 3;
        positions.push(min[0] + (i + sx / n) * step, min[1] + (j + sy / n) * step, min[2] + (k + sz / n) * step);
      }
    }
  }

  // A quad for every grid edge the surface crosses, joining the 4 cells
  // around that edge. Winding follows the sign so faces point outward.
  const indices = [];
  const quad = (a, b, c, d, flip) => {
    if (a < 0 || b < 0 || c < 0 || d < 0) return;
    if (flip) indices.push(a, c, b, a, d, c);
    else indices.push(a, b, c, a, c, d);
  };
  for (let k = 1; k < nz - 1; k++) {
    for (let j = 1; j < ny - 1; j++) {
      for (let i = 1; i < nx - 1; i++) {
        const inside = values[at(i, j, k)] < 0;
        if (inside !== values[at(i + 1, j, k)] < 0) {
          quad(cellVertex[cellAt(i, j - 1, k - 1)], cellVertex[cellAt(i, j, k - 1)],
            cellVertex[cellAt(i, j, k)], cellVertex[cellAt(i, j - 1, k)], !inside);
        }
        if (inside !== values[at(i, j + 1, k)] < 0) {
          quad(cellVertex[cellAt(i - 1, j, k - 1)], cellVertex[cellAt(i - 1, j, k)],
            cellVertex[cellAt(i, j, k)], cellVertex[cellAt(i, j, k - 1)], !inside);
        }
        if (inside !== values[at(i, j, k + 1)] < 0) {
          quad(cellVertex[cellAt(i - 1, j - 1, k)], cellVertex[cellAt(i, j - 1, k)],
            cellVertex[cellAt(i, j, k)], cellVertex[cellAt(i - 1, j, k)], !inside);
        }
      }
    }
  }

  // Snap vertices onto the true surface and take normals from the gradient.
  const count = positions.length / 3;
  const normals = new Float32Array(count * 3);
  const e = step * 0.25;
  for (let v = 0; v < count; v++) {
    let p = [positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2]];
    let g = [0, 0, 0];
    for (let it = 0; it < 3; it++) {
      const d = field(p);
      g = [
        field([p[0] + e, p[1], p[2]]) - field([p[0] - e, p[1], p[2]]),
        field([p[0], p[1] + e, p[2]]) - field([p[0], p[1] - e, p[2]]),
        field([p[0], p[1], p[2] + e]) - field([p[0], p[1], p[2] - e]),
      ];
      const gl = Math.hypot(g[0], g[1], g[2]) || 1;
      g = [g[0] / gl, g[1] / gl, g[2] / gl];
      const move = Math.max(-step * 0.5, Math.min(step * 0.5, d));
      p = [p[0] - g[0] * move, p[1] - g[1] * move, p[2] - g[2] * move];
    }
    positions[v * 3] = p[0];
    positions[v * 3 + 1] = p[1];
    positions[v * 3 + 2] = p[2];
    normals.set(g, v * 3);
  }
  return {
    positions: new Float32Array(positions),
    normals,
    indices: count > 65535 ? new Uint32Array(indices) : new Uint16Array(indices),
  };
}
