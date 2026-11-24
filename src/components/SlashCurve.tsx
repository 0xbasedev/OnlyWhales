/**
 * The exit price over the life of a lock: 100% on day one, a straight line down to 30% on the
 * last day, then a cliff to zero. `progress` (0-1) places the marker; omit it for a blank curve.
 */
export function SlashCurve({ progress, unlockLabel }: { progress?: number; unlockLabel?: string }) {
  const W = 520
  const H = 150
  const pad = { l: 44, r: 96, t: 14, b: 26 }
  const x0 = pad.l
  const x1 = W - pad.r
  const y = (pct: number) => pad.t + (1 - pct) * (H - pad.t - pad.b)
  const done = progress !== undefined && progress >= 1
  const p = Math.min(1, Math.max(0, progress ?? 0))
  const mx = done ? x1 + 46 : x0 + (x1 - x0) * p
  const my = done ? y(0) : y(1 - 0.7 * p)

  return (
    <svg className="curve" viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Early exit slash: 100% at lock start, 30% at lock end, zero after">
      <defs>
        <linearGradient id="slashFill" x1="0" x2="0" y1="0" y2="1">
          <stop offset="0" stopColor="#ff6f61" stopOpacity=".28" />
          <stop offset="1" stopColor="#ff6f61" stopOpacity="0" />
        </linearGradient>
        <linearGradient id="slashLine" x1="0" x2="1">
          <stop offset="0" stopColor="#ff6f61" />
          <stop offset="1" stopColor="#e8cc92" />
        </linearGradient>
      </defs>
      {[1, 0.3, 0].map((v) => (
        <g key={v}>
          <line x1={x0} x2={W - 8} y1={y(v)} y2={y(v)} stroke="rgba(255,255,255,.07)" strokeDasharray="2 5" />
          <text x={x0 - 10} y={y(v) + 4} textAnchor="end" fontSize="11" fill="#62757f" fontFamily="var(--mono)">
            {v * 100}%
          </text>
        </g>
      ))}
      <path d={`M${x0} ${y(1)} L${x1} ${y(0.3)} L${x1} ${y(0)} L${x0} ${y(0)} Z`} fill="url(#slashFill)" />
      <path d={`M${x0} ${y(1)} L${x1} ${y(0.3)}`} stroke="url(#slashLine)" strokeWidth="2" fill="none" strokeLinecap="round" />
      <path d={`M${x1} ${y(0.3)} L${x1} ${y(0)}`} stroke="#e8cc92" strokeWidth="2" strokeDasharray="3 4" fill="none" />
      <path d={`M${x1} ${y(0)} L${W - 8} ${y(0)}`} stroke="#7eefc1" strokeWidth="2" fill="none" strokeLinecap="round" />
      <text x={x0} y={H - 6} fontSize="11" fill="#62757f" fontFamily="var(--mono)">
        deposit
      </text>
      <text x={x1} y={H - 6} textAnchor="middle" fontSize="11" fill="#9fb1bd" fontFamily="var(--mono)">
        {unlockLabel ?? 'unlock'}
      </text>
      <text x={W - 8} y={y(0) - 8} textAnchor="end" fontSize="11" fill="#7eefc1" fontFamily="var(--mono)">
        free
      </text>
      {progress !== undefined && (
        <g style={{ transform: `translate(${mx}px, ${my}px)`, transition: 'transform 1.4s cubic-bezier(.22,.61,.36,1)' }}>
          <circle r="11" fill={done ? 'rgba(126,239,193,.18)' : 'rgba(255,111,97,.18)'} />
          <circle r="4.5" fill={done ? '#7eefc1' : '#fff'} />
        </g>
      )}
    </svg>
  )
}
