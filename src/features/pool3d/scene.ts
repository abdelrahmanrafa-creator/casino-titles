import {poolCameraPose} from '../../lib/poolCamera';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import * as T from 'three';
import {
  ballTexture,
  feltTexture,
  woodTexture,
  contactTexture,
  cushionTexture,
  brassTexture,
  createBallMaterial
} from './materials';
import { poolAimGuide } from '../../lib/poolAim';
import type { PoolTableProps } from '../PoolTable';

type BallMesh = {
  mesh: T.Mesh;
  shadow: T.Mesh;
  x: number;
  y: number;
  wasOut: boolean;
  lastRot: T.Quaternion;
};

export function createPoolScene(host: HTMLDivElement, onLost: () => void) {
  // ===== RENDERER SETUP =====
  const renderer = new T.WebGLRenderer({
    antialias: true,
    alpha: false,
    powerPreference: 'high-performance'
  });

  renderer.setClearColor('#0a0f14');
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.75));
  renderer.outputColorSpace = T.SRGBColorSpace;
  renderer.toneMapping = T.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = T.PCFSoftShadowMap;
  host.appendChild(renderer.domElement);

  // ===== SCENE & CAMERA =====
  const scene = new T.Scene();

  // Premium environment map
  const pmrem = new T.PMREMGenerator(renderer);
  const environmentRoom = new RoomEnvironment();
  const environmentTarget = pmrem.fromScene(environmentRoom, 0.04);
  scene.environment = environmentTarget.texture;
  environmentRoom.dispose();
  pmrem.dispose();

  // Dynamic camera system
  const camera = new T.PerspectiveCamera(
    45,
    host.clientWidth / Math.max(1, host.clientHeight),
    1,
    3000
  );
  camera.position.set(0, 800, 900);
  camera.lookAt(0, 0, 0);

  // Scene groups
  const ballMeshes = new Map<number, BallMesh>();
  const cue = new T.Group();
  const guide = new T.Group();
  const table = new T.Group();
  const pocketEffects = new T.Group();
  const ray = new T.Raycaster();
  const plane = new T.Plane(new T.Vector3(0, 1, 0), -11);
  const hit = new T.Vector3();

  scene.add(table, cue, guide, pocketEffects);

  // ===== STATE MANAGEMENT =====
  let props: PoolTableProps | null = null;
  let disposed = false;
  let frame = 0;
  let last = 0;
  let slow = 0;
  let frames = 0;
  let quality = 1.75;
  let dirty = true;
  let cameraTilt = 0.65;
  let cameraDistance = 900;
  let cameraHeight = 800;
  let angle = 0;
  let strike = 0;
  let displayZoom = 1;
  let focusX = 0;
  let focusZ = 0;
  let pulseKey = '';
  let pulseTime = 0;

  // ===== LIGHTING =====
  // Floor
  const floorSize = 2500;
  const floor = new T.Mesh(
    new T.PlaneGeometry(floorSize, floorSize),
    new T.MeshStandardMaterial({
      color: '#060a0f',
      envMapIntensity:0.08,
      roughness: 0.95,
      metalness: 0
    })
  );
  floor.rotation.x = -Math.PI / 2;
  floor.position.y = -130;
  floor.receiveShadow = true;
  scene.add(floor);

  // Ambient lighting
  const ambient = new T.HemisphereLight('#c0d8e0', '#0a1014', 0.9);
  scene.add(ambient);

  // Main directional light (sun)
  const mainLight = new T.DirectionalLight('#fef5e7', 2.6);
  mainLight.position.set(-250, 750, 200);
  mainLight.castShadow = true;
  mainLight.shadow.mapSize.set(2048, 2048);
  mainLight.shadow.camera.left = -700;
  mainLight.shadow.camera.right = 700;
  mainLight.shadow.camera.top = 400;
  mainLight.shadow.camera.bottom = -400;
  mainLight.shadow.camera.far = 1200;
  mainLight.shadow.bias = -0.0015;
  mainLight.shadow.normalBias = 0.7;
  mainLight.shadow.blurSamples = 8;
  scene.add(mainLight);

  // Rim light for depth
  const rimLight = new T.DirectionalLight('#7dd4e8', 0.9);
  rimLight.position.set(600, 350, -500);
  scene.add(rimLight);

  // Fill light
  const fillLight = new T.PointLight('#5fb3d5', 0.6, 1500);
  fillLight.position.set(300, 400, 400);
  scene.add(fillLight);

  // ===== MATERIALS =====
  const woodMat = new T.MeshPhysicalMaterial({
    map: woodTexture(),
    roughness: 0.32,
    metalness: 0.08,
    clearcoat: 0.65,
    clearcoatRoughness: 0.25
  });

  const brassMat = new T.MeshStandardMaterial({
    map: brassTexture(),
    metalness: 0.8,
    roughness: 0.25
  });

  const feltMat = new T.MeshStandardMaterial({
    color: '#0c5144',
    envMapIntensity:.2,
    map: feltTexture(),
    roughness: 0.96,
    metalness: 0
  });

  const cushionMat = new T.MeshStandardMaterial({
    color: '#0a4d40',
    map: cushionTexture(),
    roughness: 0.8,
    metalness: 0
  });

  const blackMat = new T.MeshStandardMaterial({
    color: '#050809',
    roughness: 0.85
  });

  // ===== TABLE GEOMETRY HELPER =====
  function box(
    w: number,
    h: number,
    d: number,
    x: number,
    y: number,
    z: number,
    material: T.Material
  ) {
    const m = new T.Mesh(
      new RoundedBoxGeometry(w, h, d, 3, Math.min(5, h / 3, d / 3)),
      material
    );
    m.position.set(x, y, z);
    m.castShadow = true;
    m.receiveShadow = true;
    table.add(m);
    return m;
  }

  // ===== BUILD TABLE =====
  // Slate layer
  box(1116, 70, 616, 0, -53, 0, blackMat);
  // Wood base
  box(1100, 42, 600, 0, -66, 0, woodMat);

  // Pocket holes
  const pocketPositions: [number, number][] = [
    [-500, -250],
    [0, -250],
    [500, -250],
    [-500, 250],
    [0, 250],
    [500, 250]
  ];

  for (const [x, z] of pocketPositions) {
    // Deep pocket well
    const well = new T.Mesh(
      new T.CylinderGeometry(25, 19, 60, 32, 1, true),
      blackMat
    );
    well.position.set(x, -25, z);
    well.castShadow = true;
    table.add(well);

    // Brass pocket rim
    const mouth = new T.Mesh(
      new T.TorusGeometry(26, 4, 8, 32),
      brassMat
    );
    mouth.rotation.x = Math.PI / 2;
    mouth.position.set(x, -0.5, z);
    mouth.castShadow = true;
    mouth.receiveShadow = true;
    table.add(mouth);

    // Bottom plate
    const base = new T.Mesh(new T.CircleGeometry(19, 32), blackMat);
    base.rotation.x = -Math.PI / 2;
    base.position.set(x, -48, z);
    table.add(base);
  }

  // Felt surface with hole cutouts
  const shape = new T.Shape();
  shape.moveTo(-475, -250);
  shape.lineTo(-25, -250);
  shape.absarc(0, -250, 25, Math.PI, 0, true);
  shape.lineTo(475, -250);
  shape.absarc(500, -250, 25, Math.PI, Math.PI / 2, true);
  shape.lineTo(500, 225);
  shape.absarc(500, 250, 25, -Math.PI / 2, -Math.PI, true);
  shape.lineTo(25, 250);
  shape.absarc(0, 250, 25, 0, -Math.PI, true);
  shape.lineTo(-475, 250);
  shape.absarc(-500, 250, 25, 0, -Math.PI / 2, true);
  shape.lineTo(-500, -225);
  shape.absarc(-500, -250, 25, Math.PI / 2, 0, true);
  shape.closePath();

  const surface = new T.Mesh(new T.ShapeGeometry(shape, 32), feltMat);
  surface.rotation.x = -Math.PI / 2;
  surface.receiveShadow = true;
  table.add(surface);

  // Wood rail sections
  for (const z of [-282, 282]) {
    for (const x of [-267, 267]) {
      box(466, 28, 37, x, 3, z, woodMat);
    }
  }
  box(37, 28, 440, -532, 3, 0, woodMat);
  box(37, 28, 440, 532, 3, 0, woodMat);

  // Decorative brass inlays
  box(1078, 2, 2, 0, 19, -298, brassMat);
  box(1078, 2, 2, 0, 19, 298, brassMat);
  box(2, 2, 580, -549, 19, 0, brassMat);
  box(2, 2, 580, 549, 19, 0, brassMat);

  // Cushion bumpers with beveled edges
  function cushion(
    x: number,
    z: number,
    length: number,
    side = false
  ) {
    const s = new T.Shape();
    s.moveTo(-length / 2 - 10, -9);
    s.lineTo(length / 2 + 10, -9);
    s.lineTo(length / 2 - 5, 10);
    s.lineTo(-length / 2 + 5, 10);
    s.closePath();

    const m = new T.Mesh(
      new T.ExtrudeGeometry(s, {
        depth: 13,
        bevelEnabled: true,
        bevelSegments: 2,
        steps: 1,
        bevelSize: 2.5,
        bevelThickness: 2
      }),
      cushionMat
    );

    m.rotation.x = -Math.PI / 2;
    if (side) m.rotation.z = Math.PI / 2;
    m.position.set(x, 1, z);
    m.castShadow = true;
    m.receiveShadow = true;
    table.add(m);
  }

  // Position cushions
  for (const z of [-256, 256]) {
    for (const x of [-250, 250]) {
      cushion(x, z, 427);
    }
  }
  for (const x of [-506, 506]) {
    cushion(x, 0, 427, true);
  }

  // Decorative dots/rivets on rails
  for (const z of [-282, 282]) {
    for (const x of [-375, -250, -125, 125, 250, 375]) {
      const dot = new T.Mesh(
        new T.OctahedronGeometry(3.8),
        brassMat
      );
      dot.position.set(x, 18, z);
      dot.scale.y = 0.3;
      dot.castShadow = true;
      table.add(dot);
    }
  }

  for (const x of [-532, 532]) {
    for (const z of [-125, 0, 125]) {
      const dot = new T.Mesh(
        new T.OctahedronGeometry(3.8),
        brassMat
      );
      dot.position.set(x, 18, z);
      dot.scale.y = 0.3;
      dot.castShadow = true;
      table.add(dot);
    }
  }

  // Logo on table center
  const logoCanvas = document.createElement('canvas');
  logoCanvas.width = 1024;
  logoCanvas.height = 256;
  const logoCtx = logoCanvas.getContext('2d')!;
  logoCtx.textAlign = 'center';
  logoCtx.fillStyle = '#d5efde20';
  logoCtx.font = 'bold 56px Georgia';
  logoCtx.fillText('LE CERCLE', 512, 128);

  const logoTexture = new T.CanvasTexture(logoCanvas);
  logoTexture.colorSpace = T.SRGBColorSpace;

  const logoMesh = new T.Mesh(
    new T.PlaneGeometry(260, 65),
    new T.MeshBasicMaterial({
      map: logoTexture,
      transparent: true,
      depthWrite: false
    })
  );
  logoMesh.rotation.x = -Math.PI / 2;
  logoMesh.position.set(0, 0.15, 0);
  table.add(logoMesh);

  // ===== BALLS =====
  const shadowTex = contactTexture();
  const ballGeo = new T.SphereGeometry(11, 32, 24);
  const shadowGeo = new T.PlaneGeometry(42, 42);

  for (let n = 0; n < 16; n++) {
    const ballMat = new T.MeshPhysicalMaterial({
      map: ballTexture(n),
      roughness: 0.12,
      metalness: 0,
      clearcoat: 1,
      clearcoatRoughness: 0.08,
      clearcoatMap: undefined,
      envMapIntensity: 1.3
    });

    const mesh = new T.Mesh(ballGeo, ballMat);
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    mesh.position.y = 11;

    // Contact shadow
    const shadowMat = new T.MeshBasicMaterial({
      map: shadowTex,
      transparent: true,
      depthWrite: false
    });

    const shadow = new T.Mesh(shadowGeo, shadowMat);
    shadow.rotation.x = -Math.PI / 2;
    shadow.position.y = 0.2;

    scene.add(mesh, shadow);
    ballMeshes.set(n, {
      mesh,
      shadow,
      x: NaN,
      y: NaN,
      wasOut: true,
      lastRot: new T.Quaternion()
    });
  }

  // ===== CUE STICK =====
  function cuePart(
    length: number,
    r1: number,
    r2: number,
    offset: number,
    color: string
  ) {
    const m = new T.Mesh(
      new T.CylinderGeometry(r1, r2, length, 16),
      new T.MeshPhysicalMaterial({
        color,
        roughness: 0.35,
        metalness: color === '#17282c' ? 0.1 : 0
      })
    );
    m.rotation.z = Math.PI / 2;
    m.position.x = offset;
    m.castShadow = true;
    cue.add(m);
  }

  // Cue shaft (tapered)
  cuePart(220, 2.3, 4.6, -135, '#e8c88a');
  // Cue handle (dark wood)
  cuePart(105, 4.6, 5.1, -292, '#1a2d32');
  // Ferrule (ivory)
  cuePart(5, 5.1, 5.1, -241, '#e0d9c3');
  // Bridge hand
  cuePart(9, 2.3, 2.3, -23, '#f0e8c5');
  // Tip ring
  cuePart(5, 2.5, 2.5, -17, '#6ec7d8');
  // Back end
  cuePart(7, 5.1, 5.1, -344, '#262729');

  // ===== AIMING GUIDE =====
  const pulseMaterial = new T.MeshBasicMaterial({
    color: '#f5db9d',
    transparent: true,
    opacity: 0,
    depthWrite: false
  });

  const pulseMesh = new T.Mesh(
    new T.RingGeometry(11, 13, 32),
    pulseMaterial
  );
  pulseMesh.rotation.x = -Math.PI / 2;
  scene.add(pulseMesh);

  // Ghost ball indicator
  const ghost = new T.Mesh(
    new T.SphereGeometry(11, 20, 16),
    new T.MeshBasicMaterial({
      color: '#fff3d0',
      wireframe: true,
      transparent: true,
      opacity: 0.35
    })
  );
  guide.add(ghost);

  // Eight bank segments plus independent object, cue and placement indicators.
  const lines = Array.from({ length: 11 }, (_, i) => {
    const geometry = new T.BufferGeometry().setFromPoints([
      new T.Vector3(),
      new T.Vector3()
    ]);

    const lineColor = i === 4 ? '#81e0f0' : '#f0dba5';
    const opacity = i === 0 ? 0.85 : i < 2 ? 0.65 : 0.45;

    const line = new T.Line(
      geometry,
      new T.LineBasicMaterial({
        color: lineColor,
        transparent: true,
        opacity,
        linewidth: 2
      })
    );
    guide.add(line);
    return line;
  });

  function setLine(
    index: number,
    a: { x: number; y: number } | undefined,
    b: { x: number; y: number } | undefined
  ) {
    const line = lines[index];
    line.visible = !!a && !!b;

    if (a && b) {
      const ar = line.geometry.attributes.position as T.BufferAttribute;
      ar.setXYZ(0, a.x - 500, 12, a.y - 250);
      ar.setXYZ(1, b.x - 500, 12, b.y - 250);
      ar.needsUpdate = true;
      line.geometry.computeBoundingSphere();
    }
  }

  // ===== POCKET ANIMATION EFFECT =====
  function createPocketPulse(x: number, z: number) {
    const pulseRing = new T.Mesh(
      new T.RingGeometry(20, 30, 16),
      new T.MeshBasicMaterial({
        color: '#6ed4a8',
        transparent: true,
        opacity: 0,
        depthWrite: false
      })
    );
    pulseRing.rotation.x = -Math.PI / 2;
    pulseRing.position.set(x, 0.5, z);
    pulseRing.userData = { createdAt: performance.now() };

    pocketEffects.add(pulseRing);

    return pulseRing;
  }

  // ===== UPDATE FUNCTION =====
  function update(p: PoolTableProps) {
    props = p;
    dirty = true;

    // Update felt color based on cloth selection
    const cloth = host
      .closest('[data-cloth]')
      ?.getAttribute('data-cloth') as string | null;

    if (cloth) {
      const colors: Record<string, [string, string]> = {
        blue: ['#155d78', '#1a495a'],
        wine: ['#69304e', '#5a2d42'],
        green: ['#0c5144', '#0a4d40']
      };

      const [feltColor, cushionColor] = colors[cloth] || colors.green!;
      feltMat.color.set(feltColor);
      cushionMat.color.set(cushionColor);
    }

    // Update balls
    for (const b of p.balls) {
      const item = ballMeshes.get(b.n);
      if (!item) continue;

      const pos = b.n === 0 ? p.white : b;
      const dx = pos.x - item.x;
      const dy = pos.y - item.y;

      item.mesh.visible = !b.out;
      item.shadow.visible = !b.out;

      const sinking = b.sink ?? 0;
      item.mesh.position.set(pos.x - 500, 11 - sinking * 38, pos.y - 250);
      item.mesh.scale.setScalar(1 - sinking * 0.55);

      // Quaternion rotation from server
      if (b.q) {
        item.mesh.quaternion.set(b.q[0], -b.q[2], b.q[1], b.q[3]).normalize();
        item.lastRot.copy(item.mesh.quaternion);
      } else if (!b.out && !item.wasOut && Number.isFinite(dx) && Math.hypot(dx, dy) < 150) {
        // Interpolate rotation based on movement
        const distance = Math.hypot(dx, dy);
        if (distance > 0.00001) {
          item.mesh.rotateOnWorldAxis(
            new T.Vector3(dy, 0, -dx).normalize(),
            distance / 11
          );
          item.lastRot.copy(item.mesh.quaternion);
        }
      }

      // Contact shadow
      item.shadow.position.set(pos.x - 500, 0.25, pos.y - 250);
      item.shadow.scale.setScalar(1 - sinking * 0.8);

      item.x = pos.x;
      item.y = pos.y;
      item.wasOut = b.out;
    }

    // Aiming guide visualization
    const g = poolAimGuide(p.balls, p.white, p.angle, p.spin);
    const target = g.target;
    const group = p.legalGroup ?? 0;
    const legal =
      !target ||
      (target.n === 8
        ? group !== 0 &&
          !p.balls.some(
            b =>
              !b.out &&
              (group === 1
                ? b.n >= 1 && b.n <= 7
                : b.n >= 9 && b.n <= 15)
          )
        : group === 0 ||
          (group === 1 ? target.n < 8 : target.n > 8));

    // Update line colors based on legality
    for (const line of lines) {
      (line.material as T.LineBasicMaterial).color.set(
        legal ? '#f0dba5' : '#f28794'
      );
    }

    guide.visible = p.aiming || !!p.placing;

    // Pulse effect when pocketing
    if (p.pulse && p.pulse.key !== pulseKey) {
      pulseKey = p.pulse.key;
      pulseTime = performance.now();
      pulseMesh.position.set(p.pulse.x - 500, 1, p.pulse.y - 250);
      pulseMaterial.color.set(
        p.pulse.kind === 'pocket' ? '#75d9b3' : '#f5db9d'
      );

      // Create pocket animation if pocketing
      if (p.pulse.kind === 'pocket' && document.documentElement.dataset.reducedMotion!=='true' && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
        createPocketPulse(p.pulse.x - 500, p.pulse.y - 250);
      }
    }

    // Draw trajectory segments
    g.segments.forEach((s, i) => setLine(i, s.from, s.to));

    // Fade out extra lines
    for (let i = g.segments.length; i < 8; i++) {
      lines[i].visible = false;
    }

    // Target and cue direction lines
    setLine(8, g.target, g.objectEnd);
    setLine(9, g.contact, g.cueEnd);
    setLine(10, p.placing ? p.white : undefined, p.placing ? { x: p.white.x + 1, y: p.white.y } : undefined);

    // Ghost ball position
    ghost.visible = !!g.contact || !!p.placing;
    if (p.placing) {
      ghost.position.set(p.white.x - 500, 11, p.white.y - 250);
      (ghost.material as T.MeshBasicMaterial).color.set(
        p.cueValid === false ? '#f07a95' : '#c5f5e0'
      );
      lines.forEach(line => (line.visible = false));
    } else if (g.contact) {
      (ghost.material as T.MeshBasicMaterial).color.set(legal?'#c5f5e0':'#f07a95');
      ghost.position.set(g.contact.x - 500, 11, g.contact.y - 250);
    }

    // Cue stick visibility and animation
    cue.visible = !!(p.aiming || p.striking);
  }

  // ===== RESIZE HANDLER =====
  function resize() {
    if (disposed) return;

    const w = Math.max(1, host.clientWidth);
    const h = Math.max(1, host.clientHeight);

    renderer.setSize(w, h, false);

    if (camera instanceof T.PerspectiveCamera) {
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
    }

    dirty = true;
  }

  const observer = new ResizeObserver(resize);
  observer.observe(host);

  // ===== ANIMATION LOOP =====
  function tick(time: number) {
    if (disposed) return;

    frame = requestAnimationFrame(tick);

    if (document.hidden) return;

    const dt = last ? Math.min(64, time - last) : 16;
    last = time;
    const p = props;

    if (!p) return;

    frames++;
    if (dt > 28) slow++;

    // Adaptive quality reduction after sustained slow frames
    if (frames === 180 && slow > 50) {
      quality = 1;
      renderer.setPixelRatio(Math.min(devicePixelRatio || 1, quality));
      renderer.shadowMap.enabled = false;
      resize();
    }

    const reduced =
      document.documentElement.dataset.reducedMotion === 'true' ||
      window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    const amount = reduced ? 1 : 1 - Math.exp(-dt / 85);

    // Smooth camera angle interpolation
    let delta = Math.atan2(
      Math.sin(p.angle - angle),
      Math.cos(p.angle - angle)
    );
    angle += delta * amount;

    // Cue stick animation (pull back on strike)
    const nextStrike = p.striking ? 52 : 0;
    strike += (nextStrike - strike) * Math.min(1, dt / 40);

    cue.rotation.y = -angle;
    cue.position.set(
      p.white.x - 500 - Math.cos(angle) * (p.power * 0.25 - strike),
      15,
      p.white.y - 250 - Math.sin(angle) * (p.power * 0.25 - strike)
    );

    // Dynamic camera system
    const targetTilt = p.viewMode === 'overhead' ? 0.001 : 0.65;
    cameraTilt += (targetTilt - cameraTilt) * amount;
    displayZoom += ((p.zoom ?? 1) - displayZoom) * amount;

    const fx =
      displayZoom > 1.05
        ? Math.max(-300, Math.min(300, p.white.x - 500))
        : 0;
    const fz =
      displayZoom > 1.05
        ? Math.max(-130, Math.min(130, p.white.y - 250))
        : 0;

    focusX += (fx - focusX) * amount;
    focusZ += (fz - focusZ) * amount;

    if (camera instanceof T.PerspectiveCamera) {
      const pose=poolCameraPose(camera.aspect,cameraTilt,displayZoom);
      camera.position.set(focusX,pose.height,focusZ+pose.depth);
      camera.lookAt(focusX, 0, focusZ);
    }

    // Pulse animation
    const pulsePhase = (time - pulseTime) / 450;
    pulseMesh.visible =
      !reduced && pulsePhase >= 0 && pulsePhase < 1;

    if (pulseMesh.visible) {
      pulseMesh.scale.setScalar(1 + pulsePhase * 2.5);
      pulseMaterial.opacity = (1 - pulsePhase) * 0.6;
    }

    // Pocket effect animations
    let effectsChanged=false;
    [...pocketEffects.children].forEach(child => {
      if(!(child instanceof T.Mesh))return;
      const elapsed = performance.now() - (child.userData.createdAt ?? 0);
      if (elapsed > 600 || reduced) {
        pocketEffects.remove(child);
        child.geometry.dispose();
        (child.material as T.Material).dispose();
        effectsChanged=true;
      } else {
        const progress = elapsed / 600;
        child.scale.setScalar(1 + progress * 3);
        (child.material as T.MeshBasicMaterial).opacity =
          Math.max(0, 0.6 * (1 - progress));
      }
    });

    // Render only if dirty or animating
    if (
      dirty ||
      pulseMesh.visible ||
      Math.abs(displayZoom - (p.zoom ?? 1)) > 0.001 ||
      Math.abs(fx - focusX) > 0.1 ||
      Math.abs(fz - focusZ) > 0.1 ||
      Math.abs(delta) > 0.0001 ||
      Math.abs(targetTilt - cameraTilt) > 0.001 ||
      Math.abs(nextStrike - strike) > 0.01 ||
      pocketEffects.children.length > 0 || effectsChanged
    ) {
      renderer.render(scene, camera);
      dirty = false;
    }
  }

  // ===== RAYCASTING FOR POINT DETECTION =====
  function point(clientX: number, clientY: number) {
    const r = renderer.domElement.getBoundingClientRect();
    const rotated =
      !!host.closest('.pool-room-expanded') &&
      matchMedia('(orientation:portrait)').matches;

    const u = rotated
      ? (clientY - r.top) / r.height
      : (clientX - r.left) / r.width;
    const v = rotated
      ? (r.right - clientX) / r.width
      : (clientY - r.top) / r.height;

    ray.setFromCamera(new T.Vector2(u * 2 - 1, 1 - v * 2), camera);

    const intersection = ray.ray.intersectPlane(plane, hit);
    if (!intersection) return null;

    return {
      x: Math.max(25, Math.min(975, hit.x + 500)),
      y: Math.max(25, Math.min(475, hit.z + 250))
    };
  }

  // ===== INITIALIZATION =====
  const lostContextHandler = (e: Event) => {
    e.preventDefault();
    onLost();
  };

  renderer.domElement.addEventListener('webglcontextlost', lostContextHandler);
  resize();
  frame = requestAnimationFrame(tick);

  // ===== CLEANUP =====
  return {
    update,
    point,
    dispose() {
      disposed = true;
      cancelAnimationFrame(frame);
      observer.disconnect();
      renderer.domElement.removeEventListener(
        'webglcontextlost',
        lostContextHandler
      );

      const geometries = new Set<T.BufferGeometry>();
      const materials = new Set<T.Material>();
      const textures = new Set<T.Texture>();

      scene.traverse(o => {
        if (o instanceof T.Mesh || o instanceof T.Line) {
          geometries.add(o.geometry);
          for (const m of Array.isArray(o.material)
            ? o.material
            : [o.material]) {
            materials.add(m);
            for (const value of Object.values(m)) {
              if (value instanceof T.Texture) {
                textures.add(value);
              }
            }
          }
        }
      });

      mainLight.shadow.dispose();
      environmentTarget.dispose();
      geometries.forEach(g => g.dispose());
      materials.forEach(m => m.dispose());
      textures.forEach(t => t.dispose());
      renderer.dispose();
      renderer.domElement.remove();
    }
  };
}

