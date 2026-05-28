import React from 'react';
import { Sequence, useCurrentFrame, interpolate, Easing } from 'remotion';

export type KeyboardOverlay = {
  atFrame: number;
  durationInFrames?: number;       // default 45
  label: string | string[];        // strings split per-char into separate keycaps
  x?: number;                      // % from left, default 50
  y?: number;                      // % from top, default 82
};

const KnockoutKey: React.FC<{ label: string }> = ({ label }) => {
  const id = React.useId();
  const maskId = `kmask-${id.replace(/:/g, '')}`;
  const w = label.length === 1 ? 140 : Math.max(140, 70 + label.length * 36);
  const h = 140;
  return (
    <svg width={w} height={h} style={{ overflow: 'visible' }}>
      <defs>
        <mask id={maskId}>
          <rect width={w} height={h} rx={22} ry={22} fill="white" />
          <text
            x="50%"
            y="50%"
            dominantBaseline="central"
            textAnchor="middle"
            fontSize={label.length === 1 ? 72 : 44}
            fontWeight={600}
            fontFamily='-apple-system, "SF Pro Display", system-ui, sans-serif'
            fill="black"
          >
            {label}
          </text>
        </mask>
      </defs>
      <rect
        width={w}
        height={h}
        rx={22}
        ry={22}
        fill="rgba(0,0,0,0.55)"
        mask={`url(#${maskId})`}
      />
    </svg>
  );
};

const KeyCapOverlay: React.FC<{ label: string | string[]; durationInFrames: number; x: number; y: number }> = ({
  label, durationInFrames, x, y,
}) => {
  const frame = useCurrentFrame();
  const fadeIn = interpolate(frame, [0, 12], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic) });
  const fadeOut = interpolate(frame, [durationInFrames - 24, durationInFrames], [1, 0], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.in(Easing.cubic) });
  const opacity = Math.min(fadeIn, fadeOut);
  const scale = interpolate(frame, [0, 8], [0.8, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic) });

  const keys = Array.isArray(label) ? label : Array.from(label);

  return (
    <div
      style={{
        position: 'absolute',
        left: `${x}%`,
        top: `${y}%`,
        transform: `translate(-50%, -50%) scale(${scale})`,
        opacity,
        pointerEvents: 'none',
        display: 'flex',
        gap: 18,
        alignItems: 'center',
      }}
    >
      {keys.map((k, i) => <KnockoutKey key={i} label={k} />)}
    </div>
  );
};

export const KeyboardOverlays: React.FC<{ overlays: KeyboardOverlay[] }> = ({ overlays }) => (
  <>
    {overlays.map((kb, i) => {
      const dur = kb.durationInFrames ?? 45;
      return (
        <Sequence key={`kb-${i}`} from={kb.atFrame} durationInFrames={dur}>
          <KeyCapOverlay
            label={kb.label}
            durationInFrames={dur}
            x={kb.x ?? 50}
            y={kb.y ?? 82}
          />
        </Sequence>
      );
    })}
  </>
);
