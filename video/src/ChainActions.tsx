import { AbsoluteFill, Video, staticFile, useCurrentFrame, interpolate, Easing, Sequence } from 'remotion';
import { KeyboardOverlay, KeyboardOverlays } from './KeyCap';

type Segment = {
  sourceStart: number;
  durationInFrames: number;
  playbackRate?: number;
};

const COMP_W = 1920;
const COMP_H = 1248;
const CENTER_X = COMP_W / 2;
const CENTER_Y = COMP_H / 2;

const segments: Segment[] = [
  { sourceStart: 934,  durationInFrames: 119,  playbackRate: 1.5 },
  { sourceStart: 1445, durationInFrames: 1141, playbackRate: 1.5 },
];

const keyboardOverlays: KeyboardOverlay[] = [
  { atFrame: 569, durationInFrames: 90, label: '⌘K' },
];

const SCALE = 1.6;

const zoomKeyframes = [
  { f: 0,    s: 1.0,   fx: CENTER_X, fy: CENTER_Y },
  { f: 90,   s: 1.0,   fx: CENTER_X, fy: CENTER_Y },
  { f: 150,  s: SCALE, fx: 895,      fy: 700      },
  { f: 569,  s: SCALE, fx: 895,      fy: 700      },
  { f: 599,  s: SCALE, fx: 960,      fy: 400      },
  { f: 1111, s: SCALE, fx: 960,      fy: 400      },
  { f: 1171, s: 1.0,   fx: CENTER_X, fy: CENTER_Y },
];

const fs  = zoomKeyframes.map(p => p.f);
const ss  = zoomKeyframes.map(p => p.s);
const txs = zoomKeyframes.map(p => CENTER_X - p.fx);
const tys = zoomKeyframes.map(p => CENTER_Y - p.fy);

export const ChainActions: React.FC = () => {
  const frame = useCurrentFrame();
  const easing = { easing: Easing.inOut(Easing.cubic), extrapolateLeft: 'clamp' as const, extrapolateRight: 'clamp' as const };

  const scale = interpolate(frame, fs, ss, easing);
  const tx = interpolate(frame, fs, txs, easing);
  const ty = interpolate(frame, fs, tys, easing);

  let cumFrame = 0;
  const seqs = segments.map((seg, i) => {
    const from = cumFrame;
    cumFrame += seg.durationInFrames;
    return (
      <Sequence
        key={i}
        from={from}
        durationInFrames={seg.durationInFrames}
        premountFor={i > 0 ? 30 : undefined}
      >
        <Video
          src={staticFile('chain_actions.mov')}
          startFrom={seg.sourceStart}
          playbackRate={seg.playbackRate ?? 1}
          style={{ width: '100%', height: '100%' }}
        />
      </Sequence>
    );
  });

  return (
    <AbsoluteFill style={{ backgroundColor: '#000' }}>
      <div
        style={{
          width: '100%',
          height: '100%',
          transform: `scale(${scale}) translate(${tx}px, ${ty}px)`,
          transformOrigin: 'center center',
        }}
      >
        {seqs}
      </div>
      <KeyboardOverlays overlays={keyboardOverlays} />
    </AbsoluteFill>
  );
};
