// Signed distance functions for sculpting a body out of smooth anatomical
// volumes. Distances are in meters; negative is inside.

export const v3 = (x, y, z) => [x, y, z];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const len = (a) => Math.sqrt(dot(a, a));
const clamp = (x, a, b) => Math.min(b, Math.max(a, x));

export function sphere(c, r) {
  return { bounds: [c, r], f: (p) => len(sub(p, c)) - r };
}

// Ellipsoid (Inigo Quilez's bound-correct approximation).
export function ellipsoid(c, r) {
  const rmax = Math.max(...r);
  return {
    bounds: [c, rmax],
    f: (p) => {
      const q = sub(p, c);
      const k0 = len([q[0] / r[0], q[1] / r[1], q[2] / r[2]]);
      const k1 = len([q[0] / (r[0] * r[0]), q[1] / (r[1] * r[1]), q[2] / (r[2] * r[2])]);
      return k1 === 0 ? -rmax : (k0 * (k0 - 1)) / k1;
    },
  };
}

// Capsule from a to b whose radius blends from ra to rb (a "round cone").
export function taper(a, b, ra, rb) {
  const ba = sub(b, a);
  const l2 = dot(ba, ba);
  const mid = [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2];
  return {
    bounds: [mid, Math.sqrt(l2) / 2 + Math.max(ra, rb)],
    f: (p) => {
      const pa = sub(p, a);
      const h = clamp(dot(pa, ba) / l2, 0, 1);
      const r = ra + (rb - ra) * h;
      return len(sub(pa, [ba[0] * h, ba[1] * h, ba[2] * h])) - r;
    },
  };
}

// Rounded box, optionally rotated about Y and then X (radians).
export function roundBox(c, half, radius, yaw = 0, pitch = 0) {
  const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
  return {
    bounds: [c, len(half) + radius],
    f: (p) => {
      let q = sub(p, c);
      q = [cy * q[0] - sy * q[2], q[1], sy * q[0] + cy * q[2]];
      q = [q[0], cp * q[1] + sp * q[2], -sp * q[1] + cp * q[2]];
      const d = [Math.abs(q[0]) - half[0], Math.abs(q[1]) - half[1], Math.abs(q[2]) - half[2]];
      const out = len([Math.max(d[0], 0), Math.max(d[1], 0), Math.max(d[2], 0)]);
      return out + Math.min(Math.max(d[0], d[1], d[2]), 0) - radius;
    },
  };
}

// Polynomial smooth minimum: blends two surfaces over a width of k.
export function smin(a, b, k) {
  if (k <= 0) return Math.min(a, b);
  const h = Math.max(k - Math.abs(a - b), 0) / k;
  return Math.min(a, b) - h * h * k * 0.25;
}

export function smax(a, b, k) {
  return -smin(-a, -b, k);
}

/**
 * A shape made of labelled parts. Each part: { shape, blend, label, cut }.
 * Parts are smooth-unioned in order (cut parts are smooth-subtracted).
 * evaluate() returns the distance and the label of the part that owns the
 * surface there (used for colors and skin weights).
 */
export class Sculpt {
  constructor() {
    this.parts = [];
  }

  add(shape, label, blend = 0.02) {
    this.parts.push({ shape, label, blend, cut: false });
    return this;
  }

  cut(shape, blend = 0.01) {
    this.parts.push({ shape, label: null, blend, cut: true });
    return this;
  }

  evaluate(p) {
    let d = Infinity;
    let label = null;
    let best = Infinity;
    for (const part of this.parts) {
      // Cheap bound test: far parts cannot change the result.
      const [c, r] = part.shape.bounds;
      const dc = len(sub(p, c)) - r;
      if (!part.cut && dc > d + part.blend && dc > best) continue;
      if (part.cut && dc > part.blend) continue;
      const di = part.shape.f(p);
      if (part.cut) {
        d = smax(d, -di, part.blend);
      } else {
        d = smin(d, di, part.blend);
        if (di < best) {
          best = di;
          label = part.label;
        }
      }
    }
    return { d, label };
  }

  distance(p) {
    return this.evaluate(p).d;
  }
}
