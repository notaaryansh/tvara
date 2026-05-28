import { AbsoluteFill, Video, staticFile, useCurrentFrame, interpolate, Easing, Sequence } from 'remotion';
import { KeyboardOverlay, KeyboardOverlays } from './KeyCap';

type ZoomPhase = {
  inStart: number;
  inEnd: number;
  outStart: number;
  outEnd: number;
  scale: number;
  focalX: number;
  focalY: number;
};

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
  { sourceStart: 273,  durationInFrames: 372 },
  { sourceStart: 1304, durationInFrames: 353 },
  { sourceStart: 2145, durationInFrames: 355 },
];

const keyboardOverlays: KeyboardOverlay[] = [
  { atFrame: 19,  durationInFrames: 90, label: '⌘K' },
  { atFrame: 435, durationInFrames: 90, label: '⌘K' },
  { atFrame: 735, durationInFrames: 90, label: '⌘K' },
];

const zoomPhases: ZoomPhase[] = [
  { inStart: 19,  inEnd: 79,  outStart: 203, outEnd: 263, scale: 2.0, focalX: 960, focalY: 380 },
  { inStart: 435, inEnd: 495, outStart: 609, outEnd: 669, scale: 2.0, focalX: 960, focalY: 380 },
  { inStart: 735, inEnd: 795, outStart: 845, outEnd: 905, scale: 2.0, focalX: 960, focalY: 380 },
];

function clampFocal(focalX: number, focalY: number, scale: number) {
  const halfW = COMP_W / (2 * scale);
  const halfH = COMP_H / (2 * scale);
  return {
    fx: Math.max(halfW, Math.min(COMP_W - halfW, focalX)),
    fy: Math.max(halfH, Math.min(COMP_H - halfH, focalY)),
  };
}

const frames = zoomPhases.flatMap(p => [p.inStart, p.inEnd, p.outStart, p.outEnd]);
const scales = zoomPhases.flatMap(p => [1, p.scale, p.scale, 1]);
const txs    = zoomPhases.flatMap(p => {
  const { fx } = clampFocal(p.focalX, p.focalY, p.scale);
  return [0, CENTER_X - fx, CENTER_X - fx, 0];
});
const tys    = zoomPhases.flatMap(p => {
  const { fy } = clampFocal(p.focalX, p.focalY, p.scale);
  return [0, CENTER_Y - fy, CENTER_Y - fy, 0];
});

export const OpenAnything: React.FC = () => {
  const frame = useCurrentFrame();
  const easing = { easing: Easing.inOut(Easing.cubic), extrapolateLeft: 'clamp' as const, extrapolateRight: 'clamp' as const };

  const scale = interpolate(frame, frames, scales, easing);
  const tx = interpolate(frame, frames, txs, easing);
  const ty = interpolate(frame, frames, tys, easing);

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
          src={staticFile('open_anything.mov')}
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
