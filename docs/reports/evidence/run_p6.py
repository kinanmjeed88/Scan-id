# Phase 6 full matrix for F-E. Synthetic planar cards only. Deterministic (seeded).
import json, math, random, sys
sys.path.insert(0, '/tmp/audit_p6')
from aspect_p6 import make_scene, assess_quad_aspect, torecipe_aspect, metric_aspect

SEED = 20261102
TRIALS = 300
results = {'seed': SEED, 'trials': TRIALS, 'groups': {}}


def r(x):
    return None if x is None else round(x, 6)


def run_case(name, card, img, f_rel, tilt_x=0, tilt_y=0, roll=0, centre=(0.5, 0.5)):
    W, H = img
    T = max(card) / min(card)
    f = f_rel * max(W, H)
    q = make_scene(card[0], card[1], W, H, f, tilt_x=math.radians(tilt_x),
                   tilt_y=math.radians(tilt_y), roll=math.radians(roll), centre_frac=centre)
    if q is None:
        return {'name': name, 'fit': False}
    a_assess, conf, accepted, angle_score = assess_quad_aspect(q, W, H)
    a_recipe = torecipe_aspect(q, W, H)
    a_known, _ = metric_aspect(q, W, H, f=f)
    a_est, f_est = metric_aspect(q, W, H)
    return {
        'name': name, 'fit': True, 'truth': round(T, 5),
        'assess_aspect': r(a_assess), 'assess_err_pct': r((a_assess / T - 1) * 100),
        'recipe_err_pct': r((a_recipe / T - 1) * 100),
        'metric_known_f_err_pct': r((a_known / T - 1) * 100),
        'metric_est_f': r(f_est), 'f_true': round(f, 1),
        'metric_est_err_pct': None if a_est is None else r((a_est / T - 1) * 100),
        'geometry_confidence': r(conf), 'angle_score': r(angle_score), 'accepted': accepted,
    }


def stats(errs):
    if not errs:
        return None
    s = sorted(abs(e) for e in errs)
    return {'n': len(errs), 'mean_abs_pct': round(sum(s) / len(s), 3),
            'p95_abs_pct': round(s[int(0.95 * (len(s) - 1))], 3), 'max_abs_pct': round(s[-1], 3)}


PORTRAIT = (3000, 4000)
LANDSCAPE = (4000, 3000)
ID1 = (85.6, 54.0)

# G1: single-axis tilt, symmetric about image centre, several focal lengths
g = []
for axis in ['tilt_x', 'tilt_y']:
    for f_rel in [0.6, 0.75, 0.9]:
        for t in [10, 20, 30, 40]:
            g.append(run_case(f'{axis}={t} f_rel={f_rel}', ID1, PORTRAIT, f_rel, **{axis: t}))
results['groups']['G1_single_axis_symmetric'] = g

# G2: in-plane roll (rotation of card within its plane, no perspective)
results['groups']['G2_inplane_roll'] = [
    run_case(f'roll={a} f_rel=0.75', ID1, PORTRAIT, 0.75, roll=a) for a in [15, 30, 45]]

# G3: two-axis (combined) perspective, signs and magnitudes
results['groups']['G3_two_axis'] = [
    run_case(f'x={x} y={y} f_rel=0.75', ID1, PORTRAIT, 0.75, tilt_x=x, tilt_y=y)
    for x, y in [(20, 20), (20, -20), (30, 10), (20, 5), (30, 30)]]

# G4: off-centre card (asymmetric relative to principal point)
results['groups']['G4_off_centre'] = [
    run_case(f'{axis}=20 centre={c}', ID1, PORTRAIT, 0.75, centre=c, **{axis: 20})
    for axis in ['tilt_x', 'tilt_y'] for c in [(0.25, 0.5), (0.75, 0.25)]]

# G5: landscape vs portrait image and card orientation
results['groups']['G5_orientation'] = [
    run_case('image portrait, card landscape', ID1, PORTRAIT, 0.75, tilt_x=20),
    run_case('image landscape, card landscape', ID1, LANDSCAPE, 0.75, tilt_x=20),
    run_case('image portrait, card portrait', (54.0, 85.6), PORTRAIT, 0.75, tilt_x=20),
    run_case('image landscape, card portrait', (54.0, 85.6), LANDSCAPE, 0.75, tilt_x=20),
]

# G6: different aspect ratios (single-axis tilt 20 deg, portrait image)
results['groups']['G6_aspect_ratios'] = [
    run_case(f'{name} tilt_x=20', dims, PORTRAIT, 0.75, tilt_x=20)
    for name, dims in [('ID-1 85.6x54', (85.6, 54.0)), ('A4 210x297', (210.0, 297.0)),
                       ('Passport 125x88', (125.0, 88.0)), ('Square 100x100', (100.0, 100.0)),
                       ('2:1 100x50', (100.0, 50.0)), ('3:1 150x50', (150.0, 50.0))]]

# G7: corner noise (pixel-space Gaussian, sigma in px), statistics over TRIALS
rng = random.Random(SEED)
noise = []
for label, kw in [('frontal', {}), ('tilt_x=20', {'tilt_x': 20}), ('tilt_x=30', {'tilt_x': 30}),
                  ('x20 y20 (two-axis)', {'tilt_x': 20, 'tilt_y': 20})]:
    W, H = PORTRAIT
    f = 0.75 * max(W, H)
    q = make_scene(ID1[0], ID1[1], W, H, f, tilt_x=math.radians(kw.get('tilt_x', 0)),
                   tilt_y=math.radians(kw.get('tilt_y', 0)))
    T = ID1[0] / ID1[1]
    for sigma in [0.0, 1.0, 2.0, 3.0]:
        e_assess, e_known, e_est = [], [], []
        for _ in range(TRIALS):
            qn = []
            for x, y in q:
                px = x * (W - 1) + rng.gauss(0, sigma)
                py = y * (H - 1) + rng.gauss(0, sigma)
                qn.append((px / (W - 1), py / (H - 1)))
            a, _, _, _ = assess_quad_aspect(qn, W, H)
            e_assess.append((a / T - 1) * 100)
            ak, _ = metric_aspect(qn, W, H, f=f)
            e_known.append((ak / T - 1) * 100)
            ae, _ = metric_aspect(qn, W, H)
            if ae is not None:
                e_est.append((ae / T - 1) * 100)
        noise.append({'case': label, 'sigma_px': sigma,
                      'assess': stats(e_assess), 'metric_known_f': stats(e_known),
                      'metric_est_f': stats(e_est) if e_est else None,
                      'metric_est_f_n_observable': len(e_est)})
results['groups']['G7_corner_noise'] = noise

# G8: systematic inward corner shift (detector shrinks quad), fraction of card side
sys_rows = []
W, H = PORTRAIT
f = 0.75 * max(W, H)
q0 = make_scene(ID1[0], ID1[1], W, H, f, tilt_x=math.radians(20))
T = ID1[0] / ID1[1]
for frac in [0.0, 0.005, 0.01, 0.02]:
    cx = sum(p[0] for p in q0) / 4
    cy = sum(p[1] for p in q0) / 4
    qs = [(p[0] + (cx - p[0]) * frac, p[1] + (cy - p[1]) * frac) for p in q0]
    a, conf, acc, _ = assess_quad_aspect(qs, W, H)
    ak, _ = metric_aspect(qs, W, H, f=f)
    sys_rows.append({'inward_shift_frac': frac, 'assess_err_pct': round((a / T - 1) * 100, 3),
                     'geometry_confidence': round(conf, 4), 'accepted': acc,
                     'metric_known_f_err_pct': round((ak / T - 1) * 100, 3)})
results['groups']['G8_systematic_inward_shift'] = sys_rows

# G9: metric sensitivity to assumed focal length (single-axis case) — f unobservable here
q1 = make_scene(ID1[0], ID1[1], W, H, f, tilt_x=math.radians(20))
results['groups']['G9_assumed_f_sensitivity_tilt_x20'] = [
    {'f_assumed_rel': fr, 'metric_err_pct': round((metric_aspect(q1, W, H, f=fr * max(W, H))[0] / T - 1) * 100, 3)}
    for fr in [0.5, 0.6, 0.7, 0.75, 0.8, 0.9, 1.0]]

# G10: one-sided edge offset (detector error on one edge only), tilt_x=20, portrait
# A uniform inward shift is a similarity and cannot change the aspect; a one-sided
# offset can. Offsets are fractions of image height (top edge moved down).
edge_rows = []
q2 = make_scene(ID1[0], ID1[1], W, H, f, tilt_x=math.radians(20))
for delta in [0.0, 0.005, 0.01, 0.02]:
    qs = [q2[0], q2[1], q2[2], q2[3]]
    qs = [(qs[0][0], qs[0][1] + delta), (qs[1][0], qs[1][1] + delta), qs[2], qs[3]]
    a, conf, acc, _ = assess_quad_aspect(qs, W, H)
    ak, _ = metric_aspect(qs, W, H, f=f)
    edge_rows.append({'top_edge_offset_frac_of_H': delta, 'assess_err_pct': round((a / T - 1) * 100, 3),
                      'geometry_confidence': round(conf, 4), 'accepted': acc,
                      'metric_known_f_err_pct': round((ak / T - 1) * 100, 3)})
results['groups']['G10_one_sided_edge_offset'] = edge_rows

out = '/tmp/audit_p6/results.json'
with open(out, 'w') as fh:
    json.dump(results, fh, indent=1)
print('written', out)
for group, rows in results['groups'].items():
    print('==', group)
    for row in rows:
        print(json.dumps(row))
