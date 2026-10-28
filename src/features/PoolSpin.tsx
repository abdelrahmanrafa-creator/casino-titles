import { useRef, type PointerEvent, type KeyboardEvent } from 'react';
import { clampSpin, type PoolSpin as Spin } from '../lib/poolAim';

interface PoolSpinProps {
  value: Spin;
  onChange: (spin: Spin) => void;
  disabled: boolean;
}

/**
 * Advanced spin control with visual feedback
 * - Drag on white ball diagram to set hit point
 * - Arrows for fine control
 * - Double-click to center
 * - Shows effect zones (draw, follow, side English)
 */
export function PoolSpin({ value, onChange, disabled }: PoolSpinProps) {
  const active = useRef<number | null>(null);
  const svgRef = useRef<SVGSVGElement>(null);

  function updateFromPointer(e: PointerEvent<SVGSVGElement>) {
    const svg = svgRef.current;
    if (!svg) return;

    const screenCTM = svg.getScreenCTM();
    if (!screenCTM) return;

    const point = new DOMPoint(e.clientX, e.clientY).matrixTransform(screenCTM.inverse());
    const x = (point.x - 60) / 36;
    const y = (60 - point.y) / 36;

    onChange(clampSpin(x, y));
  }

  function handleKeyDown(e: KeyboardEvent<SVGSVGElement>) {
    if (disabled) return;

    const step = 0.05;
    let changed = false;
    let newX = value.x;
    let newY = value.y;

    switch (e.key) {
      case 'ArrowLeft':
        newX -= step;
        changed = true;
        break;
      case 'ArrowRight':
        newX += step;
        changed = true;
        break;
      case 'ArrowUp':
        newY += step;
        changed = true;
        break;
      case 'ArrowDown':
        newY -= step;
        changed = true;
        break;
      case 'Home':
        newX = 0;
        newY = 0;
        changed = true;
        break;
    }

    if (changed) {
      e.preventDefault();
      onChange(clampSpin(newX, newY));
    }
  }

  const pixelX = 60 + value.x * 36;
  const pixelY = 60 - value.y * 36;

  // Calculate effect type and intensity
  const spinLength = Math.hypot(value.x, value.y);
  let effectLabel='Centré';
  let effectColor='#b4edd4';
  let effectIcon='⊙';
  if(spinLength>.1){
    const up=value.y>.1,down=value.y<-.1,right=value.x>.1,left=value.x<-.1;
    effectColor=up?'#5dd9e9':down?'#fdb86d':'#f08a99';
    if(up&&right){effectLabel='Coulé + effet droit';effectIcon='↗';}
    else if(up&&left){effectLabel='Coulé + effet gauche';effectIcon='↖';}
    else if(down&&right){effectLabel='Rétro + effet droit';effectIcon='↘';}
    else if(down&&left){effectLabel='Rétro + effet gauche';effectIcon='↙';}
    else if(up){effectLabel='Coulé';effectIcon='⬆';}
    else if(down){effectLabel='Rétro';effectIcon='⬇';}
    else if(right){effectLabel='Effet droit';effectIcon='➜';}
    else if(left){effectLabel='Effet gauche';effectIcon='⬅';}
  }

  return (
    <section
      data-disabled={disabled}
      className="pool-spin-control pool-spin-pro"
      aria-label="Contrôle des effets sur la bille blanche"
    >
      <div className="pool-spin-header">
        <strong>Point de frappe</strong>
        <span className="pool-spin-effect-label" style={{ color: effectColor }}>
          {effectIcon} {effectLabel}
        </span>
      </div>

      <div className="pool-spin-description">
        Glissez pour ajuster ou utilisez les flèches
      </div>

      <svg
        ref={svgRef}
        viewBox="0 0 120 120"
        className="pool-spin-ball"
        role="img"
        aria-label="Point de frappe sur la bille blanche"
        tabIndex={disabled ? -1 : 0}
        aria-disabled={disabled}
        onKeyDown={handleKeyDown}
        onDoubleClick={() => {
          if (!disabled) onChange({ x: 0, y: 0 });
        }}
        onPointerDown={e => {
          if (disabled || active.current !== null) return;
          e.preventDefault();
          active.current = e.pointerId;
          e.currentTarget.setPointerCapture(e.pointerId);
          updateFromPointer(e);
        }}
        onPointerMove={e => {
          if (active.current === e.pointerId && !disabled) {
            e.preventDefault();
            updateFromPointer(e);
          }
        }}
        onPointerUp={e => {
          if (active.current === e.pointerId) {
            active.current = null;
            if (e.currentTarget.hasPointerCapture(e.pointerId)) {
              e.currentTarget.releasePointerCapture(e.pointerId);
            }
          }
        }}
        onPointerCancel={() => {active.current = null;}}
        onLostPointerCapture={() => {active.current = null;}}
      >
        <defs>
<clipPath id="spin-effect-clip"><circle cx="60" cy="60" r="50"/></clipPath>
          {/* Glossy ball gradient */}
          <radialGradient id="spin-ball-light" cx="30%" cy="22%">
            <stop stopColor="#fff" />
            <stop offset="0.6" stopColor="#eeeee5" />
            <stop offset="1" stopColor="#747e7c" />
          </radialGradient>

          {/* Effect zone gradients */}
          <linearGradient id="draw-zone" x1="50%" y1="100%" x2="50%" y2="0%">
            <stop offset="0%" stopColor="#5dd9e9" stopOpacity="0.15" />
            <stop offset="100%" stopColor="#5dd9e9" stopOpacity="0" />
          </linearGradient>

          <linearGradient id="follow-zone" x1="50%" y1="0%" x2="50%" y2="100%">
            <stop offset="0%" stopColor="#fdb86d" stopOpacity="0.15" />
            <stop offset="100%" stopColor="#fdb86d" stopOpacity="0" />
          </linearGradient>

          <linearGradient id="english-zone-right" x1="0%" y1="50%" x2="100%" y2="50%">
            <stop offset="0%" stopColor="#f08a99" stopOpacity="0" />
            <stop offset="100%" stopColor="#f08a99" stopOpacity="0.15" />
          </linearGradient>

          <linearGradient id="english-zone-left" x1="100%" y1="50%" x2="0%" y2="50%">
            <stop offset="0%" stopColor="#f08a99" stopOpacity="0" />
            <stop offset="100%" stopColor="#f08a99" stopOpacity="0.15" />
          </linearGradient>
        </defs>

        {/* Shadow under ball */}
        <ellipse cx="63" cy="70" rx="48" ry="46" fill="#0007" />

        {/* Main ball surface */}
        <circle
          cx="60"
          cy="60"
          r="50"
          fill="url(#spin-ball-light)"
          stroke="#d6c295"
          strokeWidth="1"
        />

<g clipPath="url(#spin-effect-clip)">        {/* Effect zones */}
        <rect x="12" y="12" width="96" height="36" fill="url(#draw-zone)" rx="4" />
        <rect x="12" y="72" width="96" height="36" fill="url(#follow-zone)" rx="4" />
        <rect x="12" y="12" width="36" height="96" fill="url(#english-zone-left)" ry="4" />
        <rect x="72" y="12" width="36" height="96" fill="url(#english-zone-right)" ry="4" />

</g>
        {/* Highlight */}
        <ellipse
          cx="43"
          cy="30"
          rx="15"
          ry="5"
          fill="#fff"
          opacity="0.8"
          transform="rotate(-25 43 30)"
        />

        {/* Center cross lines */}
        <path
          d="M60 22v76M22 60h76"
          stroke="#66716f"
          strokeOpacity="0.25"
          strokeDasharray="3 4"
          strokeWidth="0.5"
        />

        {/* Radius circle (effect boundary) */}
        <circle
          cx="60"
          cy="60"
          r="36"
          fill="none"
          stroke="#66716f44"
          strokeDasharray="2 5"
          strokeWidth="0.5"
        />

        {/* Directional indicator zones */}
        <g opacity="0.3">
          {/* Top zone label */}
          <text
            x="60"
            y="18"
            textAnchor="middle"
            fontSize="8"
            fill="#5dd9e9"
            fontWeight="bold"
          >
            Coulé
          </text>

          {/* Bottom zone label */}
          <text
            x="60"
            y="102"
            textAnchor="middle"
            fontSize="8"
            fill="#fdb86d"
            fontWeight="bold"
          >
            Rétro
          </text>

          {/* Left zone label */}
          <text
            x="18"
            y="63"
            textAnchor="middle"
            fontSize="8"
            fill="#f08a99"
            fontWeight="bold"
          >
            Gauche
          </text>

          {/* Right zone label */}
          <text
            x="102"
            y="63"
            textAnchor="middle"
            fontSize="8"
            fill="#f08a99"
            fontWeight="bold"
          >
            Droite
          </text>
        </g>

        {/* Current hit point (draggable) */}
        <circle
          cx={pixelX}
          cy={pixelY}
          r="7"
          fill={effectColor}
          stroke="#fff"
          strokeWidth="2"
          style={{ cursor: disabled ? 'default' : 'grab' }}
        />

        {/* Inner dot for precision */}
        <circle cx={pixelX} cy={pixelY} r="2" fill="#fff4c8" />

        {/* Connection line from center */}
        {spinLength > 0.05 && (
          <>
            <line
              x1="60"
              y1="60"
              x2={pixelX}
              y2={pixelY}
              stroke={effectColor}
              strokeWidth="1"
              strokeOpacity="0.5"
              strokeDasharray="2 2"
            />
            {/* Distance indicator */}
            <text
              x={(60 + pixelX) / 2}
              y={(60 + pixelY) / 2 - 4}
              textAnchor="middle"
              fontSize="7"
              fill={effectColor}
              opacity="0.7"
              style={{fontVariantNumeric:"tabular-nums"}}
            >
              {Math.round(spinLength * 100)}%
            </text>
          </>
        )}
      </svg>

      {/* Accessibility controls */}
      <div className="pool-spin-accessibility">
        <label>
          Effet latéral
          <input
            type="range"
            min={-1}
            max={1}
            step={0.05}
            aria-label="Effet latéral (gauche à droite)"
            disabled={disabled}
            value={value.x}
            onChange={e => onChange(clampSpin(Number(e.target.value), value.y))}
          />
        </label>

        <label>
          Effet rétro ou coulé
          <input
            type="range"
            min={-1}
            max={1}
            step={0.05}
            aria-label="Effet rétro (-) ou coulé (+)"
            disabled={disabled}
            value={value.y}
            onChange={e => onChange(clampSpin(value.x, Number(e.target.value)))}
          />
        </label>
      </div>

      {/* Status text */}
      <p className="pool-spin-status">
        Haut: Coulé · Bas: Rétro · Côtés: Effet de bande
      </p>

      <small className="pool-spin-hint">
        Double-cliquez ou Début pour centrer
      </small>

      <style>{`
        .pool-spin-header {
          display: flex;
          justify-content: space-between;
          align-items: center;
          margin-bottom: 8px;
          font-size: 0.875rem;
          gap: 12px;
        }

        .pool-spin-effect-label {
          font-weight: bold;
          font-size: 1rem;
          white-space: nowrap;
          font-family: system-ui, sans-serif;
          letter-spacing: 2px;
        }

        .pool-spin-description {
          font-size: 0.8rem;
          color: #999;
          margin-bottom: 8px;
          text-align: center;
        }

        .pool-spin-ball {
          cursor: ${disabled ? 'default' : 'grab'};
          padding: 12px;
          background: radial-gradient(circle at 30% 30%, rgba(255,255,255,0.05), transparent);
          border-radius: 8px;
          border: 1px solid rgba(100, 150, 180, 0.2);
          margin: 0 auto;
          display: block;
          max-width: 280px;
          transition: border-color 0.2s;
        }

        .pool-spin-ball:hover {
          border-color: rgba(100, 200, 240, 0.4);
        }

        .pool-spin-accessibility {
          display: flex;
          flex-direction: column;
          gap: 12px;
          margin-top: 12px;
        }

        .pool-spin-accessibility label {
          display: flex;
          flex-direction: column;
          gap: 6px;
          font-size: 0.85rem;
        }

        .pool-spin-accessibility input {
          height: 24px;
          cursor: ${disabled ? 'default' : 'pointer'};
        }

        .pool-spin-status {
          margin-top: 8px;
          text-align: center;
          font-size: 0.85rem;
          color: #999;
        }

        .pool-spin-hint {
          display: block;
          margin-top: 4px;
          text-align: center;
          font-size: 0.75rem;
          color: #666;
        }
      `}</style>
    </section>
  );
}

