import * as THREE from 'three';

// Ball colors - bright, professionally accurate
export const ballColors = [
  '#fff9e8', // 0: white
  '#eab622', // 1: yellow
  '#2162bd', // 2: blue
  '#ca2636', // 3: red
  '#6935a9', // 4: purple
  '#e97722', // 5: orange
  '#168c63', // 6: green
  '#84223e', // 7: maroon
  '#11141b', // 8: black (solid)
  '#eab622', // 9: yellow stripe
  '#2162bd', // 10: blue stripe
  '#ca2636', // 11: red stripe
  '#6935a9', // 12: purple stripe
  '#e97722', // 13: orange stripe
  '#168c63', // 14: green stripe
  '#84223e'  // 15: maroon stripe
];

/**
 * Create a canvas texture with custom drawing
 * Optimized for mobile and desktop with proper color space
 */
export function canvasTexture(
  draw: (c: CanvasRenderingContext2D, size: number) => void,
  size = 512
) {
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = size;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw Error('Canvas unavailable');

  draw(ctx, size);

  const t = new THREE.CanvasTexture(canvas);
  t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 4;

  return t;
}

/**
 * High-quality ball texture with visible numbers and proper 3D look
 * - Solid colors for solids (1-7, white)
 * - Stripes and numbers for stripes (9-15)
 * - Sheen and gloss for realism
 */
export function ballTexture(n: number) {
  return canvasTexture((c, s) => {
    const baseColor = ballColors[n];
    const isStriped = n > 8;

    // Base fill
    c.fillStyle = isStriped ? '#fff9e8' : baseColor;
    c.fillRect(0, 0, s, s);

    // Stripe band for striped balls
    if (isStriped) {
      const stripColor = ballColors[n];
      const stripHeight = s * 0.35;
      const stripY = (s - stripHeight) / 2;
      c.fillStyle = stripColor;
      c.fillRect(0, stripY, s, stripHeight);


    }

    // Ball number(s) - visible and clear
    if (n !== 0) {
      const numberPositions = [
            [s * 0.25, s * 0.35],
            [s * 0.75, s * 0.35],
            [s * 0.25, s * 0.65],
            [s * 0.75, s * 0.65]
          ];

      for (const [x, y] of numberPositions) {
        // White circle background
        c.fillStyle = '#fff9e9';
        c.beginPath();
        c.arc(x, y, s * 0.085, 0, Math.PI * 2);
        c.fill();

        // Black border
        c.strokeStyle = '#161820';
        c.lineWidth = s * 0.012;
        c.stroke();

        // Number text
        c.fillStyle = '#161820';
        c.font = `bold ${s * 0.11}px "Arial Black", sans-serif`;
        c.textAlign = 'center';
        c.textBaseline = 'middle';
        c.fillText(String(n), x, y);

        // Stripe mark on striped balls
        if (isStriped) {
          c.fillStyle = '#16182088';
          c.fillRect(x - s * 0.028, y + s * 0.06, s * 0.056, s * 0.008);
        }
      }
    } else {
      // White ball - tiny red spots
      c.fillStyle = '#c43248';
      for (const x of [0.25, 0.75]) {
        for (const y of [0.25, 0.5, 0.75]) {
          c.beginPath();
          c.arc(s * x, s * y, s * 0.01, 0, Math.PI * 2);
          c.fill();
        }
      }
    }

    // Subtle gloss gradient at top
    const glossGradient = c.createLinearGradient(0, 0, 0, s * 0.3);
    glossGradient.addColorStop(0, 'rgba(255,255,255,0.15)');
    glossGradient.addColorStop(1, 'rgba(255,255,255,0)');
    c.fillStyle = glossGradient;
    c.fillRect(0, 0, s, s * 0.3);
  }, 512);
}

/**
 * Premium felt texture with realistic weave pattern
 */
export function feltTexture() {
  const t = canvasTexture((c, s) => {
    // Base color
    c.fillStyle = '#fff';
    c.fillRect(0, 0, s, s);

    // Weave pattern with seeded randomness
    let seed = 51;
    for (let i = 0; i < 25000; i++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const x = seed % s;

      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const y = seed % s;

      c.fillStyle = i % 3 === 0 ? '#dcdcd8' : '#efefeb';
      c.globalAlpha = 0.8 + (seed/4294967296) * 0.2;
      const size = 1 + (i % 2);
      c.fillRect(x, y, size, size);
    }
    c.globalAlpha = 1;

    // Subtle texture overlay
    for (let i = 0; i < 100; i++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const x = seed % s;
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const y = seed % s;

      c.strokeStyle = `rgba(200,200,200,${0.05 + (seed/4294967296) * 0.05})`;
      c.lineWidth = 0.5;
      c.beginPath();
      c.moveTo(x, y);
      c.lineTo(x + (seed % 8) - 4, y + ((seed >>> 16) % 8) - 4);
      c.stroke();
    }
  }, 256);

  t.wrapS = t.wrapT = THREE.RepeatWrapping;
  t.repeat.set(12, 6);
  return t;
}

/**
 * Realistic wood texture for table rails
 */
export function woodTexture() {
  const t = canvasTexture((c, s) => {
    // Base wood color
    c.fillStyle = '#6b4829';
    c.fillRect(0, 0, s, s);

    // Wood grain pattern
    let seed = 42;
    for (let i = 0; i < 120; i++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const yPos = (i * 5) % s;

      // Primary grain
      c.strokeStyle = i % 4 === 0 ? '#8b5a2b' : '#a0642a';
      c.lineWidth = 1 + (i % 3);
      c.globalAlpha = 0.6;
      c.beginPath();
      c.moveTo(0, yPos);

      const frequency = 0.4 + (i % 3) * 0.1;
      for (let x = 0; x < s; x += 10) {
        const noise = Math.sin(x * frequency + i * 0.7) * 5;
        c.lineTo(x, yPos + noise);
      }
      c.stroke();
    }
    c.globalAlpha = 1;

    // Shine and wear marks
    c.strokeStyle = 'rgba(255,255,255,0.08)';
    c.lineWidth = 1;
    for (let i = 0; i < 40; i++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const x = seed % s;
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const y = seed % s;
      c.beginPath();
      c.moveTo(x, y);
      c.lineTo(x + ((seed >>> 16) % 40) - 20, y + ((seed >>> 8) % 20) - 10);
      c.stroke();
    }
  }, 256);

  t.wrapS = t.wrapT = THREE.RepeatWrapping;
  t.repeat.set(3, 1);
  return t;
}

/**
 * Dynamic contact shadow texture - will be created during render
 */
export function contactTexture() {
  return canvasTexture((c, s) => {
    const g = c.createRadialGradient(s / 2, s / 2, s * 0.08, s / 2, s / 2, s / 2);
    g.addColorStop(0, 'rgba(0, 0, 0, 0.12)');
    g.addColorStop(0.4, 'rgba(0, 0, 0, 0.08)');
    g.addColorStop(0.8, 'rgba(0, 0, 0, 0.03)');
    g.addColorStop(1, 'rgba(0, 0, 0, 0)');

    c.fillStyle = g;
    c.fillRect(0, 0, s, s);

    // Add subtle edge vignette
    const vignette = c.createRadialGradient(s / 2, s / 2, s * 0.5, s / 2, s / 2, s);
    vignette.addColorStop(0, 'rgba(0, 0, 0, 0)');
    vignette.addColorStop(1, 'rgba(0, 0, 0, 0.05)');
    c.fillStyle = vignette;
    c.fillRect(0, 0, s, s);
  }, 64);
}

/**
 * Cushion/rubber texture for table bumpers
 */
export function cushionTexture() {
  return canvasTexture((c, s) => {
    // Base rubber color
    c.fillStyle = '#0d5142';
    c.fillRect(0, 0, s, s);

    // Rubber grip pattern
    let seed = 123;
    for (let i = 0; i < 2000; i++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const x = seed % s;
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const y = seed % s;

      c.fillStyle = i % 2 === 0 ? '#114d40' : '#0d5142';
      c.globalAlpha = 0.7;
      c.fillRect(x, y, 2, 2);
    }
    c.globalAlpha = 1;

    // Wear marks
    c.strokeStyle = 'rgba(255,255,255,0.03)';
    c.lineWidth = 1;
    for (let i = 0; i < 30; i++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const x = seed % s;
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const y = seed % s;
      c.beginPath();
      c.arc(x, y, 10 + (i % 5) * 3, 0, Math.PI * 2);
      c.stroke();
    }
  }, 128);
}

/**
 * Brass/metal texture for pocket rings and rails
 */
export function brassTexture() {
  return canvasTexture((c, s) => {
    // Base brass color with radial gradient
    const g = c.createRadialGradient(s * 0.3, s * 0.3, s * 0.1, s / 2, s / 2, s * 0.8);
    g.addColorStop(0, '#f4d8a8');
    g.addColorStop(0.5, '#d4a858');
    g.addColorStop(1, '#a67c28');

    c.fillStyle = g;
    c.fillRect(0, 0, s, s);

    // Fine scratches and wear
    c.strokeStyle = 'rgba(255,255,255,0.1)';
    c.lineWidth = 0.5;
    let seed = 234;
    for (let i = 0; i < 100; i++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const x = seed % s;
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const y = seed % s;
      c.beginPath();
      c.moveTo(x, y);
      c.lineTo(x + ((seed >>> 16) % 30) - 15, y + ((seed >>> 8) % 5) - 2);
      c.stroke();
    }
  }, 128);
}

/**
 * Shiny ball material for improved reflections
 */
export function createBallMaterial(ballIndex: number, isStriped: boolean) {
  const texture = ballTexture(ballIndex);

  return new THREE.MeshPhysicalMaterial({
    map: texture,
    roughness: 0.12,
    metalness: 0,
    clearcoat: 1,
    clearcoatRoughness: 0.08,
    clearcoatMap: undefined,
    normalScale: new THREE.Vector2(0.8, 0.8),
    envMapIntensity: 1.2
  });
}

