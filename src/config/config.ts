'use client';

import { getDefaultConfig } from '@rainbow-me/rainbowkit';
import { http } from 'wagmi';
import {morphHolesky} from 'wagmi/chains';

export const config = getDefaultConfig({
  appName: 'My RainbowKit App',
  projectId: 'YOUR_PROJECT_ID', 
  chains: [morphHolesky],
  ssr: true,
  transports: {
    [morphHolesky.id]: http(''),
  },
});
