// Same order and meaning as `enum Codec` in Sources/Codecs.swift
export const CODECS = [
  { label: 'Lossless', kind: 'none' },
  { label: 'Ogg 320', kind: 'vorbis', q: 0.9 },   // Spotify: Ogg Vorbis 44.1 kHz
  { label: 'Ogg 160', kind: 'vorbis', q: 0.5 },
  { label: 'Ogg 96', kind: 'vorbis', q: 0.2 },
  { label: 'Opus', kind: 'opus', bitrate: 128000 },  // YouTube itag 251
  { label: 'AAC 128', kind: 'aac', bitrate: 128000 }, // YouTube itag 140
  { label: 'AAC 160', kind: 'aac', bitrate: 160000 }, // SoundCloud HLS AAC 160
  { label: 'AAC 256', kind: 'aac', bitrate: 256000 }, // SoundCloud Go+
  { label: 'Opus 64', kind: 'opus', bitrate: 64000 },  // SoundCloud legacy HLS Opus
]

export const SPOTIFY = [0, 1, 2, 3]
export const YOUTUBE = [4, 5]
export const SOUNDCLOUD = [6, 7, 8]
