import { Composition } from 'remotion';
import { Demo } from './Demo';
import { OpenAnything } from './OpenAnything';
import { ChainActions } from './ChainActions';

export const Root = () => {
  return (
    <>
      <Composition
        id="Demo"
        component={Demo}
        durationInFrames={3078}
        fps={60}
        width={1920}
        height={1248}
      />
      <Composition
        id="OpenAnything"
        component={OpenAnything}
        durationInFrames={1080}
        fps={60}
        width={1920}
        height={1248}
      />
      <Composition
        id="ChainActions"
        component={ChainActions}
        durationInFrames={1260}
        fps={60}
        width={1920}
        height={1248}
      />
    </>
  );
};
