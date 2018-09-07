function init_joined_tracking(systems::Vector{T}, inits::Vector{Initials}, sample_freqs, interm_freqs, pll_bandwidth, dll_bandwidth, sat_prn) where T <: AbstractGNSSSystem
    gen_code_replicas = map((system, init, sample_freq) -> init_code_replica(system, system.code_freq + init.code_doppler, init.code_phase, sample_freq, sat_prn), systems, inits, sample_freqs)
    gen_carrier_replicas = map((init, interm_freq, sample_freq) -> init_carrier_replica(interm_freq + init.carrier_doppler, init.carrier_phase, sample_freq), inits, interm_freqs, sample_freqs)
    carrier_loop = init_carrier_loop(pll_bandwidth)
    code_loop = init_code_loop(dll_bandwidth)
    (signals, beamform, velocity_aidings = zeros(length(systems))) -> _joined_tracking(systems, signals, sample_freqs, beamform, gen_carrier_replicas, gen_code_replicas, 0.0, 0.0, carrier_loop, code_loop, velocity_aidings)
end

function _joined_tracking(systems, signals, sample_freqs, beamform, gen_carrier_replicas, gen_code_replicas, carrier_freq_update, code_freq_update, carrier_loop, code_loop, velocity_aidings)
    num_systems = length(systems)
    num_samples = [size(signal, 1) for signal in signals]
    num_ants = sum([size(signal, 2) for signal in signals])
    Δts = map((num_samples, sample_freq) -> num_samples / sample_freq, num_samples, sample_freqs)
    if !all(Δts .== Δts[1])
        error("Signal time interval must be identical for all given signals.")
    end
    Δt = Δts[1]

    center_freq_geometric_mean = prod([system.center_freq for system in systems])^(1 / num_systems)
    code_freq_geometric_mean = prod([system.code_freq for system in systems])^(1 / num_systems)
    
    intermediate_results = map(systems, signals, sample_freqs, gen_carrier_replicas, gen_code_replicas, velocity_aidings) do system, signal, sample_freq, gen_carrier_replica, gen_code_replica, velocity_aiding
        gen_replica_downconvert_correlate(system, signal, sample_freq, gen_carrier_replica, gen_code_replica, carrier_freq_update, code_freq_update, center_freq_geometric_mean, code_freq_geometric_mean, velocity_aiding)
    end
    tracking_results = [intermediate_result[1] for intermediate_result in intermediate_results]
    correlated_signals = [intermediate_result[2] for intermediate_result in intermediate_results]
    next_gen_carrier_replicas = [intermediate_result[3] for intermediate_result in intermediate_results]
    next_gen_code_replicas = [intermediate_result[4] for intermediate_result in intermediate_results]

    joined_correlated_signals = reduce(vcat, correlated_signals)
    beamformed_signal = beamform(joined_correlated_signals)

    next_carrier_loop, next_carrier_freq_update = carrier_loop(beamformed_signal, Δt)
    next_code_loop, next_code_freq_update = code_loop(beamformed_signal, Δt)

    (next_signals, next_beamform, next_velocity_aidings = zeros(length(systems))) -> _joined_tracking(systems, next_signals, sample_freqs, next_beamform, next_gen_carrier_replicas, next_gen_code_replicas, next_carrier_freq_update, next_code_freq_update, next_carrier_loop, next_code_loop, next_velocity_aidings), tracking_results
end