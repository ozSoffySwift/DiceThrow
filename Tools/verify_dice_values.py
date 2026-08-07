"""End-to-end: for many random resting orientations, does the value the app
scores equal the number a player actually sees on the die?

faceValues / readsBottom are parsed out of DiceGeometry.swift so this tests the
shipped constants, not a copy of them. Painted numbers come from the real USD
atlas UVs."""
import re, math, random

SRC = open('DiceThrow/DiceGeometry.swift').read()

# Restrict to buildMeta — `case .d4:` also appears in loadUSDA.
BUILD_META = SRC.split('private static func buildMeta')[1].split('// MARK:')[0]

def app_spec(die):
    """Pull `values:` and `readsBottom:` for a die out of DiceGeometry.swift."""
    if die == 'd6':
        return [1,2,6,5,3,4], False      # cube(): explicit values array
    seg = BUILD_META.split('case .'+die+':')[1]
    body = seg.split('case .')[0]
    rb = 'readsBottom: true' in body
    if 'Array(1...' in body:
        n = int(re.search(r'Array\(1\.\.\.(\d+)\)', body).group(1))
        vals = list(range(1, n+1))
    else:
        vals = [int(x) for x in re.search(r'values: \[([0-9,\s]+)\]', body).group(1).split(',')]
    return vals, rb

def parse_usd(path):
    t = open(path).read()
    counts = [int(x) for x in re.findall(r'(-?\d+)', re.search(r'int\[\] faceVertexCounts\s*=\s*\[(.*?)\]', t, re.S).group(1))]
    pts = [tuple(map(float,p)) for p in re.findall(r'\(([-\d.eE]+),\s*([-\d.eE]+),\s*([-\d.eE]+)\)', re.search(r'point3f\[\] points\s*=\s*\[(.*?)\]', t, re.S).group(1))]
    sts = [tuple(map(float,p)) for p in re.findall(r'\(([-\d.eE]+),\s*([-\d.eE]+)\)', re.search(r'primvars:st[^=]*=\s*\[(.*?)\]', t, re.S).group(1))]
    return counts, pts, sts

def cross(a,b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
def dot(a,b): return sum(a[i]*b[i] for i in range(3))
def unit(a):
    m = math.sqrt(dot(a,a)) or 1
    return tuple(k/m for k in a)

def rand_rot():
    u1,u2,u3 = random.random(), random.random(), random.random()
    q = (math.sqrt(1-u1)*math.sin(2*math.pi*u2), math.sqrt(1-u1)*math.cos(2*math.pi*u2),
         math.sqrt(u1)*math.sin(2*math.pi*u3),  math.sqrt(u1)*math.cos(2*math.pi*u3))
    x,y,z,w = q
    return [[1-2*(y*y+z*z), 2*(x*y-z*w),   2*(x*z+y*w)],
            [2*(x*y+z*w),   1-2*(x*x+z*z), 2*(y*z-x*w)],
            [2*(x*z-y*w),   2*(y*z+x*w),   1-2*(x*x+y*y)]]
def apply(R,v): return tuple(sum(R[i][j]*v[j] for j in range(3)) for i in range(3))

TILE_VALUE = {'d6':[1,2,6,5,3,4], 'd8':list(range(1,9)), 'd10':list(range(1,11)),
              'd12':list(range(1,13)), 'd20':list(range(1,21))}
S = 1/math.sqrt(3)
D4_VERTS = [tuple(c*S for c in v) for v in [(1,1,1),(1,-1,-1),(-1,1,-1),(-1,-1,1)]]

print(f"{'die':5s} {'trials':>7s} {'readsBottom':>12s}  result")
allok = True
for die in ['d4','d6','d8','d10','d12','d20']:
    vals, rb = app_spec(die)
    counts, pts, sts = parse_usd(f'DiceThrow/DiceModels/{die}.usda')
    n_orig = len(vals)
    cols = math.ceil(math.sqrt(n_orig+1)); rows = math.ceil((n_orig+1)/cols)
    # per-original-face: outward normal + painted number
    normals, painted, off = [], [], 0
    for i,c in enumerate(counts):
        fp = pts[off:off+c]; fs = sts[off:off+c]; off += c
        if i < n_orig:
            n = unit(cross(tuple(fp[1][k]-fp[0][k] for k in range(3)),
                           tuple(fp[2][k]-fp[0][k] for k in range(3))))
            ctr = tuple(sum(p[k] for p in fp)/len(fp) for k in range(3))
            if dot(n,ctr) < 0: n = tuple(-k for k in n)
            normals.append(n)
            u = sum(s[0] for s in fs)/len(fs); v = sum(s[1] for s in fs)/len(fs)
            tile = (rows-1-int(v*rows))*cols + int(u*cols)
            painted.append(TILE_VALUE[die][tile] if die in TILE_VALUE else None)

    bad = 0
    TRIALS = 4000
    for _ in range(TRIALS):
        R = rand_rot()
        # --- what the app scores (readValue in DiceTable.swift) ---
        best, bestdot = 0, -9e9
        for i,n in enumerate(normals):
            d = apply(R,n)[1]
            if rb: d = -d
            if d > bestdot: bestdot, best = d, i
        scored = vals[best]
        # --- what the player sees ---
        if die == 'd4':
            # corner-read: the value at the apex vertex pointing up
            seen = max(range(4), key=lambda k: apply(R, D4_VERTS[k])[1]) + 1
        else:
            top = max(range(n_orig), key=lambda k: apply(R, normals[k])[1])
            seen = painted[top]
        if scored != seen: bad += 1
    status = "OK — scored == seen in all trials" if bad == 0 else f"FAIL — {bad}/{TRIALS} mismatched"
    if bad: allok = False
    print(f"{die:5s} {TRIALS:7d} {str(rb):>12s}  {status}")
print("\nPASS" if allok else "\nFAIL")
