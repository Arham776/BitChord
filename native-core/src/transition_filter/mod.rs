//! TransitionFilter (spec §3.5): verbatim port of upstream
//! `TransitionFilterProcessor` — trapezoidal-integrator state-variable
//! Butterworth LP/HP pair (24 dB/oct) with geometrically gliding cutoffs,
//! re-aimed per fade tick for bass hand-off during transitions.
