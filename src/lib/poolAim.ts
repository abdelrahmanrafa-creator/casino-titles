/**
 * Enhanced pooling aim and trajectory geometry
 * - Multiple bounce predictions (up to 8 segments)
 * - Realistic spin physics
 * - Improved ghost ball placement
 * - Legality checking
 */

export type PoolPoint = { x: number; y: number };
export type PoolBall = PoolPoint & { n: number; out: boolean };
export type PoolSpin = { x: number; y: number };

/**
 * Calculate animation progress with smooth easing
 */
export function poolAnimationProgress(
  time: number,
  start: number,
  duration: number
): number {
  return Math.max(0, Math.min(1, (time - start) / Math.max(1, duration)));
}

/**
 * Check if a line segment is clear of obstacles
 * Used for validating shot trajectories
 */
export function poolSegmentClear(
  balls: PoolBall[],
  from: PoolPoint,
  to: PoolPoint,
  ignored: number[]
): boolean {
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  const len = Math.max(1, dx * dx + dy * dy);

  return !balls.some(b => {
    if (b.out || ignored.includes(b.n)) return false;

    // Project ball position onto line segment
    const t = Math.max(0, Math.min(1, ((b.x - from.x) * dx + (b.y - from.y) * dy) / len));
    const closestDist = Math.hypot(
      b.x - from.x - t * dx,
      b.y - from.y - t * dy
    );

    return closestDist < 23; // Ball radius + tolerance
  });
}

/**
 * Suggest a good opening shot for the current game state
 * Returns angle, power, target ball and pocket
 */
export function poolSuggestedShot(
  balls: PoolBall[],
  white: PoolPoint,
  group: number
): {
  angle: number;
  power: number;
  target: number;
  pot: boolean;
  rank: number;
} | null {
  // Get valid target balls based on group
  const own = balls.filter(
    b =>
      !b.out &&
      (group === 1
        ? b.n >= 1 && b.n <= 7
        : group === 2
        ? b.n >= 9 && b.n <= 15
        : b.n !== 0 && b.n !== 8)
  );

  const targets = own.length ? own : balls.filter(b => b.n === 8 && !b.out);

  let best: ReturnType<typeof poolSuggestedShot> = null;

  // Try pocketing each target
  for (const b of targets) {
    // Test against all 6 pockets
    for (const [x, y] of [
      [0, 0],
      [500, 0],
      [1000, 0],
      [0, 500],
      [500, 500],
      [1000, 500]
    ]) {
      const dx = x - b.x;
      const dy = y - b.y;
      const len = Math.hypot(dx, dy);

      if (len < 1) continue;

      // Ghost position: where cue ball should hit target ball to pocket it
      const ghost: PoolPoint = {
        x: b.x - (dx / len) * 22,
        y: b.y - (dy / len) * 22
      };

      // Distance from white to ghost position
      const distance = Math.hypot(ghost.x - white.x, ghost.y - white.y);

      // Validate path is free
      if (
        distance < 1 ||
        ghost.x < 12 ||
        ghost.x > 988 ||
        ghost.y < 12 ||
        ghost.y > 488
      ) {
        continue;
      }

      // Check cut angle (how much the ball is hit off-center)
      const cut = ((b.x - ghost.x) * (ghost.x - white.x) + (b.y - ghost.y) * (ghost.y - white.y)) / (22 * distance);

      if (cut < 0.15) continue; // Cut too thin

      // Verify paths are clear
      if (
        !poolSegmentClear(balls, white, ghost, [0, b.n]) ||
        !poolSegmentClear(balls, b, { x, y }, [0, b.n])
      ) {
        continue;
      }

      // Score this shot (lower is better)
      const score =
        distance +
        len / Math.max(0.35, cut) +
        200 * (1 - cut);

      if (!best || score < best.rank) {
        best = {
          angle: Math.atan2(ghost.y - white.y, ghost.x - white.x),
          power: Math.round(
            Math.min(100, Math.max(20, (distance + len / Math.max(0.35, cut)) / 10 + 10))
          ),
          target: b.n,
          pot: true,
          rank: score
        };
      }
    }
  }

  // If no pocket found, try bank shots
  if (best) return best;

  const breaking =
    group === 0 &&
    targets.length === 14 &&
    Math.max(...targets.map(b => b.x)) - Math.min(...targets.map(b => b.x)) < 130 &&
    Math.max(...targets.map(b => b.y)) - Math.min(...targets.map(b => b.y)) < 130;

  for (const b of targets) {
    const distance = Math.hypot(b.x - white.x, b.y - white.y);

    if (distance < 1) continue;

    const ghost: PoolPoint = {
      x: b.x - ((b.x - white.x) / distance) * 22,
      y: b.y - ((b.y - white.y) / distance) * 22
    };

    if (!poolSegmentClear(balls, white, ghost, [0, b.n])) continue;

    if (
      !best ||
      distance < best.rank
    ) {
      best = {
        angle: Math.atan2(b.y - white.y, b.x - white.x),
        power: breaking ? 100 : 55,
        target: b.n,
        pot: false,
        rank: distance
      };
    }
  }

  return best;
}

/**
 * Normalize angle to [-π, π] range
 */
export function normalizeAngle(angle: number): number {
  return Math.atan2(Math.sin(angle), Math.cos(angle));
}

/**
 * Clamp spin values to unit circle
 */
export function clampSpin(x: number, y: number): PoolSpin {
  const length = Math.hypot(x, y);
  const scale = length > 1 ? 1 / length : 1;
  return { x: x * scale, y: y * scale };
}

/**
 * Check if a position is free for ball placement (ball in hand)
 */
export function cuePositionFree(balls: PoolBall[], p: PoolPoint): boolean {
  return (
    p.x >= 25 &&
    p.x <= 975 &&
    p.y >= 25 &&
    p.y <= 475 &&
    !balls.some(
      b =>
        b.n !== 0 &&
        !b.out &&
        Math.hypot(b.x - p.x, b.y - p.y) < 23
    )
  );
}

/**
 * Fine aim adjustment with mouse/touch sensitivity
 */
export function fineAim(
  start: number,
  pointerStart: number,
  pointerNow: number
): number {
  return normalizeAngle(start + normalizeAngle(pointerNow - pointerStart) * 0.18);
}

export type AimGuide = {
  segments: { from: PoolPoint; to: PoolPoint }[];
  contact?: PoolPoint;
  target?: PoolBall;
  objectEnd?: PoolPoint;
  cueEnd?: PoolPoint;
};

/** Keep short post-contact guides on the playing surface. */
export function poolProjectedRayEnd(from:PoolPoint,direction:PoolPoint,maximum:number):PoolPoint{
 const len=Math.hypot(direction.x,direction.y);if(len<1e-9)return {...from};
 const dx=direction.x/len,dy=direction.y/len;
 const wallX=dx>1e-9?(989-from.x)/dx:dx< -1e-9?(11-from.x)/dx:Infinity;
 const wallY=dy>1e-9?(489-from.y)/dy:dy< -1e-9?(11-from.y)/dy:Infinity;
 const distance=Math.max(0,Math.min(maximum,wallX,wallY));
 return {x:from.x+dx*distance,y:from.y+dy*distance};
}

/**
 * Calculate full aiming guide with multiple bounces and spin effects
 * - Up to 8 trajectory segments with bounce physics
 * - Spin-based direction changes on cushion impacts
 * - Ghost ball placement for visual reference
 * - Cue end position for spin visualization
 */
export function poolAimGuide(
  balls: PoolBall[],
  white: PoolPoint,
  angle: number,
  spin: PoolSpin = { x: 0, y: 0 }
): AimGuide {
  let origin = { ...white };
  let direction = {
    x: Math.cos(angle),
    y: Math.sin(angle)
  };

  const guide: AimGuide = { segments: [] };

  // Maximum 8 segments for trajectory visualization
  const maxBounces = 8;

  for (let bounce = 0; bounce < maxBounces; bounce++) {
    // Calculate distances to walls
    const wallX =
      direction.x > 1e-9
        ? (989 - origin.x) / direction.x
        : direction.x < -1e-9
        ? (11 - origin.x) / direction.x
        : Infinity;

    const wallY =
      direction.y > 1e-9
        ? (489 - origin.y) / direction.y
        : direction.y < -1e-9
        ? (11 - origin.y) / direction.y
        : Infinity;

    // Find closest obstruction (ball or wall)
    let distance = Math.max(0, Math.min(wallX, wallY));
    let target: PoolBall | undefined;

    // Check for ball collisions
    for (const b of balls) {
      if (b.n === 0 || b.out) continue;

      const dx = b.x - origin.x;
      const dy = b.y - origin.y;
      const projection = dx * direction.x + dy * direction.y;
      const perp = dx * dx + dy * dy - projection * projection;

      if (projection <= 0 || perp > 22 * 22) continue;

      // Distance to ball surface
      const hit = projection - Math.sqrt(Math.max(0, 22 * 22 - perp));

      if (hit >= 0 && hit < distance) {
        distance = hit;
        target = b;
      }
    }

    // Add segment to guide
    const end: PoolPoint = {
      x: origin.x + direction.x * distance,
      y: origin.y + direction.y * distance
    };

    guide.segments.push({ from: origin, to: end });

    // If hit a ball, calculate impact effects
    if (target) {
      const nx = (target.x - end.x) / 22;
      const ny = (target.y - end.y) / 22;
      const impact = Math.max(0, direction.x * nx + direction.y * ny);

      guide.contact = end;
      guide.target = target;

      // Project target ball trajectory
      guide.objectEnd = poolProjectedRayEnd(target,{x:nx,y:ny},180);

      // Calculate cue end position showing spin effect
      const cx =
        direction.x - impact * nx + Math.cos(angle) * spin.y * 0.36;
      const cy =
        direction.y - impact * ny + Math.sin(angle) * spin.y * 0.36;
      const len = Math.hypot(cx, cy);

      if (len > 0.02) {
        guide.cueEnd = poolProjectedRayEnd(end,{x:cx,y:cy},130);
      }

      break;
    }

    // Check if we hit a pocket (stop bouncing)
    if (
      [
        [0, 0],
        [500, 0],
        [1000, 0],
        [0, 500],
        [500, 500],
        [1000, 500]
      ].some(([x, y]) => Math.hypot(end.x - x, end.y - y) < 30)
    ) {
      break;
    }

    // Bounce off wall with spin influence
    if (wallX < wallY) {
      // Vertical wall bounce
      direction = {
        x: -direction.x * 0.88,
        y: direction.y + Math.abs(direction.x) * 0.88 * spin.x * 0.22 * (end.x < 500 ? -1 : 1)
      };
    } else {
      // Horizontal wall bounce
      direction = {
        x: direction.x + Math.abs(direction.y) * 0.88 * spin.x * 0.22 * (end.y < 250 ? 1 : -1),
        y: -direction.y * 0.88
      };
    }

    // Normalize direction vector
    const length = Math.hypot(direction.x, direction.y);
    direction = {
      x: direction.x / length,
      y: direction.y / length
    };

    // Advance origin with small offset to prevent re-collision
    origin = {
      x: end.x + direction.x * 0.01,
      y: end.y + direction.y * 0.01
    };
  }

  return guide;
}

/**
 * Check if cue is playable (white ball is free or placed)
 */
export function poolCuePlayable(
  balls: PoolBall[],
  point: PoolPoint,
  inHand: boolean
): boolean {
  return !inHand || cuePositionFree(balls, point);
}

