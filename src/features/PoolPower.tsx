import {poolPullPoint,poolPullGesture} from '../lib/poolPowerGesture';
import { useRef, useState, type PointerEvent } from 'react';

interface PoolPowerProps {
  value: number;
  onChange: (v: number) => void;
  disabled: boolean;
  onRelease?: (power: number) => void;
}

/**
 * Professional pool power control with visual feedback
 * - Drag down to pull cue back
 * - Drag sideways to cancel
 * - Visual power indicator with smooth scaling
 */
export function PoolPower({ value, onChange, disabled, onRelease }: PoolPowerProps) {
  const active = useRef<{
    id: number;
    startPos: number;
    startCross: number;
    power: number;
    cancelled: boolean;
    distance: number;
    crossDistance: number;
  } | null>(null);

  const [pulling, setPulling] = useState(false);
  const [cancelled, setCancelled] = useState(false);
  const [momentum, setMomentum] = useState(0);

  const railRef = useRef<HTMLDivElement>(null);

  function handlePointerMove(e: PointerEvent<HTMLDivElement>) {
    const a = active.current;
    if (!a || a.id !== e.pointerId) return;

    const rail = railRef.current;
    if (!rail) return;

    const bounds = rail.getBoundingClientRect();
    const rotated =
      !!e.currentTarget.closest('.pool-room-expanded') &&
      matchMedia('(orientation:portrait)').matches;

    const gesture=poolPullGesture(a.startPos,a.startCross,e.clientX,e.clientY,bounds.width,bounds.height,rotated);
    const mainDistance=gesture.distance;
    const isCancelled=gesture.cancelled;
    a.distance=mainDistance;
    a.crossDistance=gesture.crossDistance;
    a.cancelled=isCancelled;
    setCancelled(isCancelled);

    if (!isCancelled) {
      // Calculate power with smooth curve
      const ratio = gesture.ratio;
      const power = Math.round(100 * Math.pow(ratio, 1.25));
      a.power = Math.max(5, Math.min(100, power));
      onChange(a.power);

      // Visual momentum feedback
      setMomentum(ratio);
    }
  }

  function handlePointerUp(e: PointerEvent<HTMLDivElement>) {
    const a = active.current;
    if (!a) return;

    const rail = railRef.current;
    if (!rail) return;

    const bounds = rail.getBoundingClientRect();

    // Fire only if:
    // 1. Not disabled
    // 2. Not cancelled
    // 3. Moved minimum distance (12px)
    // 4. Power is at least 5%
    const shouldFire =
      !disabled &&
      !a.cancelled &&
      a.distance >= 12 &&
      a.power >= 5;

    active.current = null;
    setPulling(false);
    setCancelled(false);
    setMomentum(0);

    if (e.currentTarget.hasPointerCapture(e.pointerId)) {
      e.currentTarget.releasePointerCapture(e.pointerId);
    }

    if (shouldFire) {
      onRelease?.(Math.max(5, a.power));
    } else {
      onChange(5);
    }
  }

  function handleCancel() {
    active.current = null;
    setPulling(false);
    setCancelled(false);
    setMomentum(0);
    onChange(5);
  }

  const powerPercent = Math.round((value / 100) * 100);
  const isActive = pulling && !cancelled;

  return (
    <aside
      className={`pool-power pool-power-pro ${disabled ? 'disabled ' : ''}${pulling ? 'pulling ' : ''}${cancelled ? 'cancelled ' : ''}`}
      role="region"
      aria-label="Puissance de tir"
    >
      <div className="pool-power-header">
        <label htmlFor="pool-power" className="pool-power-label">
          Queue de tir
        </label>
        <span className="pool-power-percent">
          {powerPercent}%
        </span>
      </div>

      <div
        className="pool-pull-rail"
        ref={railRef}
        onPointerDown={e => {
          if (disabled || active.current) return;

          e.preventDefault();
          const rotated =
            !!e.currentTarget.closest('.pool-room-expanded') &&
            matchMedia('(orientation:portrait)').matches;

          const bounds = e.currentTarget.getBoundingClientRect();
          const {main:mainAxis,cross:crossAxis}=poolPullPoint(e.clientX,e.clientY,rotated);

          active.current = {
            id: e.pointerId,
            startPos: mainAxis,
            startCross: crossAxis,
            power: 5,
            cancelled: false,
            distance: 0,
            crossDistance: 0
          };

          e.currentTarget.setPointerCapture(e.pointerId);
          setPulling(true);
          onChange(5);
        }}
        onPointerMove={e => {
          if (active.current?.id === e.pointerId && !disabled) {
            handlePointerMove(e);
          }
        }}
        onPointerUp={e => {
          if (active.current?.id === e.pointerId) {
            handlePointerUp(e);
          }
        }}
        onPointerCancel={handleCancel}
        onLostPointerCapture={() => {
          if (active.current) handleCancel();
        }}
        aria-label="Réglez la puissance du tir en tirant vers le bas"
        aria-disabled={disabled}
      >
        {/* Power indicator bars */}
        <div className="pool-power-bars">
          {Array.from({ length: 10 }, (_, i) => (
            <div
              key={i}
              className={`pool-power-bar ${i < Math.ceil((value / 100) * 10) ? 'active' : ''}`}
              style={{
                height: `${((i + 1) / 10) * 100}%`
              }}
            />
          ))}
        </div>

        {/* Cue visual representation */}
        <div className="pool-pull-cue" style={{ top: `${(value / 100) * 48}%` }}>
          <i />
          <b />
        </div>

        {/* Grid background */}
        <span className="pool-power-ticks" />
      </div>

      {/* Keyboard accessible range input */}
      <input
        className="pool-accessible-range"
        id="pool-power"
        aria-label="Puissance du tir"
        type="range"
        min={5}
        max={100}
        step={1}
        value={value}
        disabled={disabled}
        onChange={e => onChange(Number(e.target.value))}
        onKeyDown={e => {
          if (e.key === 'Enter' && !disabled) {
            onRelease?.(value);
          } else if (e.key === 'Escape') {
            handleCancel();
          }
        }}
      />

      {/* Status message */}
      <div className="pool-power-status">
        {cancelled ? (
          <small className="pool-power-cancelled">Tir annulé</small>
        ) : pulling ? (
          <small className="pool-power-pulling">Relâchez pour tirer</small>
        ) : (
          <small className="pool-power-hint">Tirez puis relâchez</small>
        )}
      </div>

      {/* Cancel hint */}
      <span className="pool-pull-cancel-hint">
        {cancelled ? '✓ Annulé' : 'Glissez sur le côté pour annuler'}
      </span>

      <style>{`
        .pool-power-bars {
          position: absolute;
          left: 0;
          top: 0;
          width: 100%;
          height: 100%;
          display: grid;
          grid-template-columns: repeat(10, 1fr);
          gap: 2px;
          padding: 2px;
          pointer-events: none;
        }

        .pool-power-bar {
          background: linear-gradient(to top, #6ec7d8, #81e0f0);
          opacity: 0.3;
          border-radius: 2px;
          transition: opacity 0.15s ease;
        }

        .pool-power-bar.active {
          opacity: 0.8;
          box-shadow: 0 0 8px rgba(110, 199, 216, 0.6);
        }

        .pool-pull-rail.pulling .pool-power-bar.active {
          box-shadow: 0 0 12px rgba(110, 199, 216, 0.9);
        }

        .pool-pull-rail.cancelled .pool-power-bar {
          background: linear-gradient(to top, #f08a99, #f2a8b0);
        }

        .pool-power-header {
          display: flex;
          justify-content: space-between;
          align-items: center;
          margin-bottom: 8px;
          font-size: 0.875rem;
        }

        .pool-power-percent {
          font-weight: bold;
          color: #6ec7d8;
          font-variant-numeric: tabular-nums;
          min-width: 3em;
          text-align: right;
        }

        .pool-power-status {
          text-align: center;
          margin-top: 8px;
          min-height: 18px;
        }

        .pool-power-cancelled {
          color: #f08a99;
        }

        .pool-power-pulling {
          color: #6ec7d8;
          font-weight: bold;
        }

        .pool-power-hint {
          color: #999;
          font-size: 0.8rem;
        }
      `}</style>
    </aside>
  );
}

