package aos_vs_soa_bench

import obench "../../obench"

// A 64-byte particle, of which the integration step only touches position and velocity.
// With an array of structs the loop pulls whole particles through the cache. With Odin's
// `#soa` layout it reads only those two fields.
Particle :: struct {
	pos:      [3]f32,
	vel:      [3]f32,
	color:    [4]f32,
	mass:     f32,
	lifetime: f32,
	flags:    u64,
	padding:  [2]u32,
}

// @zero_alloc
// @params(1024, 16384, 65536)
bench_integrate__aos :: proc(b: ^obench.Bencher) {
	n := obench.param(b)
	particles := make([]Particle, n)
	defer delete(particles)

	for &p, i in particles {
		f := f32(i + 1)
		p.pos = {f, f * 0.5, f * 0.25}
		p.vel = {0.1, 0.2, 0.3}
		p.mass = 1.0
	}

	dt := f32(0.016)
	obench.set_items(b, u64(n))
	obench.set_bytes(b, u64(n * size_of(Particle)))

	for obench.step(b) {
		step_dt := obench.black_box(dt)
		for &p in particles {
			p.pos[0] += p.vel[0] * step_dt
			p.pos[1] += p.vel[1] * step_dt
			p.pos[2] += p.vel[2] * step_dt
		}
		obench.keep_alive(&particles[0])
	}
}

// @zero_alloc
// @params(1024, 16384, 65536)
bench_integrate__soa :: proc(b: ^obench.Bencher) {
	n := obench.param(b)
	particles := make(#soa[]Particle, n)
	defer delete(particles)

	for i in 0 ..< n {
		f := f32(i + 1)
		particles[i].pos = {f, f * 0.5, f * 0.25}
		particles[i].vel = {0.1, 0.2, 0.3}
		particles[i].mass = 1.0
	}

	dt := f32(0.016)
	obench.set_items(b, u64(n))
	obench.set_bytes(b, u64(n * size_of(Particle)))

	for obench.step(b) {
		step_dt := obench.black_box(dt)
		for i in 0 ..< n {
			particles.pos[i][0] += particles.vel[i][0] * step_dt
			particles.pos[i][1] += particles.vel[i][1] * step_dt
			particles.pos[i][2] += particles.vel[i][2] * step_dt
		}
		obench.keep_alive(&particles.pos[0])
	}
}
