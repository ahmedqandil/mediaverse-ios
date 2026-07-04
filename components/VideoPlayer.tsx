/**
 * Native video player with custom controls, HLS, progress bar, and Like Moment.
 * Uses expo-video (VideoView + useVideoPlayer).
 */
import { useRef, useState, useCallback, useEffect } from 'react';
import {
  View, Text, TouchableOpacity, StyleSheet, Dimensions, PanResponder,
  Animated, type ViewStyle,
} from 'react-native';
import { VideoView, useVideoPlayer } from 'expo-video';
import { C } from '@/lib/constants';

const { width: SW } = Dimensions.get('window');

interface Props {
  src:            string;
  poster?:        string;
  autoPlay?:      boolean;
  style?:         ViewStyle;
  onEnded?:       () => void;
  onTimeUpdate?:  (current: number, duration: number) => void;
  onLikeMoment?:  (sec: number) => void;
  userLikedSeconds?: number[];
}

function fmt(s: number) {
  if (!isFinite(s) || s < 0) return '0:00';
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = Math.floor(s % 60);
  if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`;
  return `${m}:${String(sec).padStart(2, '0')}`;
}

export function VideoPlayer({
  src, autoPlay = true, style,
  onEnded, onTimeUpdate, onLikeMoment, userLikedSeconds = [],
}: Props) {
  const [playing,     setPlaying]     = useState(autoPlay);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration,    setDuration]    = useState(0);
  const [showCtrl,    setShowCtrl]    = useState(true);
  const [fullscreen,  setFullscreen]  = useState(false);
  const hideTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const progressAnim = useRef(new Animated.Value(0)).current;

  const player = useVideoPlayer(src, p => {
    p.loop = false;
    if (autoPlay) p.play();
  });

  // Poll currentTime
  useEffect(() => {
    const id = setInterval(() => {
      if (!player) return;
      const ct = player.currentTime ?? 0;
      const dur = player.duration ?? 0;
      setCurrentTime(ct);
      setDuration(dur);
      onTimeUpdate?.(ct, dur);
      if (dur > 0) {
        Animated.timing(progressAnim, {
          toValue: ct / dur,
          duration: 100,
          useNativeDriver: false,
        }).start();
      }
    }, 250);
    return () => clearInterval(id);
  }, [player, onTimeUpdate, progressAnim]);

  // Auto-hide controls
  const resetHide = useCallback(() => {
    setShowCtrl(true);
    if (hideTimer.current) clearTimeout(hideTimer.current);
    hideTimer.current = setTimeout(() => { if (playing) setShowCtrl(false); }, 3000);
  }, [playing]);

  useEffect(() => { resetHide(); }, [playing, resetHide]);

  const togglePlay = () => {
    if (playing) { player.pause(); setPlaying(false); }
    else         { player.play();  setPlaying(true);  }
    resetHide();
  };

  const skip = (secs: number) => {
    player.currentTime = Math.max(0, Math.min(duration, currentTime + secs));
    resetHide();
  };

  // Seek bar pan
  const barRef = useRef<View>(null);
  const [barX, setBarX] = useState(0);
  const [barW, setBarW] = useState(SW);
  const panResponder = PanResponder.create({
    onStartShouldSetPanResponder: () => true,
    onPanResponderGrant: (e) => {
      const pct = Math.max(0, Math.min(1, (e.nativeEvent.pageX - barX) / barW));
      player.currentTime = pct * duration;
      resetHide();
    },
    onPanResponderMove: (e) => {
      const pct = Math.max(0, Math.min(1, (e.nativeEvent.pageX - barX) / barW));
      player.currentTime = pct * duration;
    },
  });

  const pct = duration > 0 ? currentTime / duration : 0;
  const isLiked = userLikedSeconds.includes(Math.floor(currentTime));

  return (
    <TouchableOpacity
      activeOpacity={1}
      onPress={resetHide}
      style={[styles.container, style]}
    >
      {/* Video */}
      <VideoView
        player={player}
        style={StyleSheet.absoluteFill}
        contentFit="contain"
        nativeControls={false}
        allowsFullscreen={fullscreen}
      />

      {/* Always-visible thin progress bar at bottom */}
      <View style={styles.alwaysBar}>
        <Animated.View
          style={[
            styles.alwaysProgress,
            { width: progressAnim.interpolate({ inputRange: [0,1], outputRange: ['0%','100%'] }) },
          ]}
        />
      </View>

      {/* Controls overlay */}
      {showCtrl && (
        <View style={styles.overlay}>
          {/* Gradient scrim */}
          <View style={styles.scrim} />

          {/* Transport row */}
          <View style={styles.transport}>
            <TouchableOpacity onPress={() => skip(-10)} style={styles.ctrlBtn}>
              <SkipIcon back />
            </TouchableOpacity>
            <TouchableOpacity onPress={togglePlay} style={[styles.ctrlBtn, styles.playBtn]}>
              {playing ? <PauseIcon /> : <PlayIcon />}
            </TouchableOpacity>
            <TouchableOpacity onPress={() => skip(10)} style={styles.ctrlBtn}>
              <SkipIcon />
            </TouchableOpacity>
          </View>

          {/* Bottom section: seek bar + time + like */}
          <View style={styles.bottom}>

            {/* Seek bar */}
            <View
              ref={barRef}
              onLayout={e => { setBarW(e.nativeEvent.layout.width); }}
              onStartShouldSetResponder={() => false}
              style={styles.seekTrack}
              {...panResponder.panHandlers}
            >
              <View style={[styles.seekFilled, { width: `${pct * 100}%` }]} />
              <View style={[styles.seekThumb, { left: `${pct * 100}%` as unknown as number }]} />
            </View>

            {/* Time + Like moment */}
            <View style={styles.timeRow}>
              <Text style={styles.time}>{fmt(currentTime)} / {fmt(duration)}</Text>
              <View style={styles.spacer} />
              {onLikeMoment && (
                <TouchableOpacity
                  onPress={() => onLikeMoment(Math.floor(currentTime))}
                  style={[styles.likeBtn, isLiked && styles.likeBtnActive]}
                >
                  <HeartIcon filled={isLiked} />
                  <Text style={[styles.likeTxt, isLiked && { color: C.watch }]}>
                    Moment
                  </Text>
                </TouchableOpacity>
              )}
              <TouchableOpacity
                onPress={() => setFullscreen(f => !f)}
                style={styles.ctrlBtn}
              >
                <FullscreenIcon on={fullscreen} />
              </TouchableOpacity>
            </View>
          </View>
        </View>
      )}
    </TouchableOpacity>
  );
}

// ── Icons ─────────────────────────────────────────────────────────────────────

function PlayIcon() {
  return (
    <View style={{ width: 22, height: 22, alignItems: 'center', justifyContent: 'center' }}>
      <Text style={{ color: '#fff', fontSize: 20 }}>▶</Text>
    </View>
  );
}
function PauseIcon() {
  return <Text style={{ color: '#fff', fontSize: 20, letterSpacing: 3 }}>⏸</Text>;
}
function SkipIcon({ back }: { back?: boolean }) {
  return <Text style={{ color: 'rgba(255,255,255,0.8)', fontSize: 16 }}>{back ? '⏮' : '⏭'}</Text>;
}
function HeartIcon({ filled }: { filled: boolean }) {
  return <Text style={{ fontSize: 13, color: filled ? C.watch : 'rgba(255,255,255,0.75)' }}>
    {filled ? '♥' : '♡'}
  </Text>;
}
function FullscreenIcon({ on }: { on: boolean }) {
  return <Text style={{ color: 'rgba(255,255,255,0.8)', fontSize: 14 }}>{on ? '⊡' : '⊞'}</Text>;
}

// ── Styles ─────────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: { backgroundColor: '#000', aspectRatio: 16/9, width: '100%' },
  alwaysBar: {
    position: 'absolute', bottom: 0, left: 0, right: 0, height: 2,
    backgroundColor: 'rgba(255,255,255,0.15)', zIndex: 5,
  },
  alwaysProgress: { height: '100%', backgroundColor: C.watch },
  overlay: {
    ...StyleSheet.absoluteFillObject, zIndex: 10,
    justifyContent: 'flex-end',
  },
  scrim: {
    position: 'absolute', bottom: 0, left: 0, right: 0, height: 150,
    // Simulate gradient with opacity layers
    backgroundColor: 'rgba(0,0,0,0.55)',
  },
  transport: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 24, marginBottom: 12,
  },
  ctrlBtn: { width: 44, height: 44, alignItems: 'center', justifyContent: 'center' },
  playBtn: { width: 52, height: 52 },
  bottom: { paddingHorizontal: 14, paddingBottom: 12 },
  seekTrack: {
    height: 20, justifyContent: 'center', marginBottom: 6, position: 'relative',
  },
  seekFilled: {
    position: 'absolute', left: 0, top: '50%',
    marginTop: -2, height: 4, borderRadius: 2,
    backgroundColor: C.watch,
  },
  seekThumb: {
    position: 'absolute', top: '50%', marginTop: -7,
    width: 14, height: 14, borderRadius: 7,
    backgroundColor: C.watch, marginLeft: -7,
  },
  timeRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  time: { color: 'rgba(255,255,255,0.7)', fontSize: 11, fontVariant: ['tabular-nums'] },
  spacer: { flex: 1 },
  likeBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    paddingHorizontal: 10, paddingVertical: 6,
    borderRadius: 20, backgroundColor: 'rgba(255,255,255,0.10)',
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.15)',
  },
  likeBtnActive: {
    backgroundColor: `${C.watch}22`,
    borderColor: `${C.watch}77`,
  },
  likeTxt: { fontSize: 11, fontWeight: '600', color: 'rgba(255,255,255,0.75)' },
});
