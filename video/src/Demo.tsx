import { AbsoluteFill, Audio, Video, staticFile, useCurrentFrame, interpolate, Easing, Sequence } from 'remotion';
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

type AudioCue = {
  atFrame: number;
  sound: 'received' | 'sent';      // maps to public/sounds/{received,sent}.m4a
  volume?: number;                 // 0-1, default 1
};

const COMP_W = 1920;
const COMP_H = 1248;
const CENTER_X = COMP_W / 2;
const CENTER_Y = COMP_H / 2;

const segments: Segment[] = [
  { sourceStart: 270, durationInFrames: 120  },
  { sourceStart: 540, durationInFrames: 120  },
  { sourceStart: 780, durationInFrames: 2838 },
];

const keyboardOverlays: KeyboardOverlay[] = [
  { atFrame: 491, durationInFrames: 90, label: '⌘K' },
  { atFrame: 925, durationInFrames: 90, label: '⌘↩' },
];

const audioCues: AudioCue[] = [];

function clampFocal(focalX: number, focalY: number, scale: number) {
  const halfW = COMP_W / (2 * scale);
  const halfH = COMP_H / (2 * scale);
  return {
    fx: Math.max(halfW, Math.min(COMP_W - halfW, focalX)),
    fy: Math.max(halfH, Math.min(COMP_H - halfH, focalY)),
  };
}

const zoomPhases: ZoomPhase[] = [
  { inStart: 30,   inEnd: 90,   outStart: 450,  outEnd: 510,  scale: 2.2,  focalX: 1500, focalY: 260 },
  { inStart: 750,  inEnd: 810,  outStart: 1800, outEnd: 1860, scale: 2.2,  focalX: 960,  focalY: 350 },
  { inStart: 2070, inEnd: 2130, outStart: 3030, outEnd: 3078, scale: 1.25, focalX: 1000, focalY: 700 },
];

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

export const Demo: React.FC = () => {
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
          src={staticFile('product_demo.mov')}
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
      {audioCues.map((cue, i) => (
        <Sequence key={`audio-${i}`} from={cue.atFrame}>
          <Audio src={staticFile(`sounds/${cue.sound}.m4a`)} volume={cue.volume ?? 1} />
        </Sequence>
      ))}
    </AbsoluteFill>
  );
};
