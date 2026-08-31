use std::sync::Mutex;

use rten::Model;
use rten_tensor::prelude::*;

static BEAT: Mutex<Option<Model>> = Mutex::new(None);
static VOCAL: Mutex<Option<Model>> = Mutex::new(None);

/// Load ONNX graphs from paths the Swift side resolved out of the app bundle.
/// Empty paths unload that model. Returns whether the beat tracker is ready
/// (vocals are optional — Automix still beat-matches without a mask).
pub fn configure(beat_path: &str, vocal_path: &str) -> bool {
    {
        let mut slot = BEAT.lock().unwrap();
        *slot = if beat_path.is_empty() {
            None
        } else {
            match Model::load_file(beat_path) {
                Ok(model) => {
                    log::info!("automix: loaded beat model from {beat_path}");
                    Some(model)
                }
                Err(err) => {
                    log::warn!("automix: beat model failed to load ({err}); energy fallback");
                    None
                }
            }
        };
    }
    {
        let mut slot = VOCAL.lock().unwrap();
        *slot = if vocal_path.is_empty() {
            None
        } else {
            match Model::load_file(vocal_path) {
                Ok(model) => {
                    log::info!("automix: loaded vocal model from {vocal_path}");
                    Some(model)
                }
                Err(err) => {
                    log::warn!("automix: vocal model failed to load ({err}); no mask");
                    None
                }
            }
        };
    }
    analyzer_ready()
}

pub fn analyzer_ready() -> bool {
    BEAT.lock().unwrap().is_some()
}

pub fn with_beat<T>(f: impl FnOnce(&Model) -> T) -> Option<T> {
    let slot = BEAT.lock().unwrap();
    slot.as_ref().map(f)
}

pub fn with_vocal<T>(f: impl FnOnce(&Model) -> T) -> Option<T> {
    let slot = VOCAL.lock().unwrap();
    slot.as_ref().map(f)
}

/// Flatten an rten output tensor of unknown rank into a contiguous f32 buffer.
pub fn flatten_f32(value: &rten::Value) -> Option<Vec<f32>> {
    value.as_tensor_view::<f32>().map(|view| view.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_bundled_beat_model() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../AppleApp/Resources/Models/beat_this.onnx"
        );
        if !std::path::Path::new(path).is_file() {
            eprintln!("skip: {path} not present");
            return;
        }
        let model = Model::load_file(path).expect("beat model should load");
        assert!(!model.input_ids().is_empty());
        assert!(
            model.output_ids().len() >= 2,
            "Beat This! has beat + downbeat heads, got {}",
            model.output_ids().len()
        );
        eprintln!(
            "beat inputs={} outputs={} params={}",
            model.input_ids().len(),
            model.output_ids().len(),
            model.total_params()
        );
        for (i, id) in model.input_ids().iter().enumerate() {
            let info = model.node_info(*id).unwrap();
            eprintln!("  in[{i}] {:?} {:?}", info.name(), info.shape());
        }
        for (i, id) in model.output_ids().iter().enumerate() {
            let info = model.node_info(*id).unwrap();
            eprintln!("  out[{i}] {:?} {:?}", info.name(), info.shape());
        }
        // One dummy chunk so a missing op fails here instead of at Automix time.
        let frames = 64usize;
        let chunk = vec![0.0f32; frames * 128];
        let tensor = rten_tensor::NdTensor::from_data([1, frames, 128], chunk);
        let outputs = model
            .run(
                vec![(*model.input_ids().first().unwrap(), tensor.into())],
                model.output_ids(),
                None,
            )
            .expect("beat dummy infer");
        assert!(flatten_f32(&outputs[0]).map(|v| v.len()).unwrap_or(0) >= frames);
    }

    #[test]
    fn load_bundled_vocal_model() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../AppleApp/Resources/Models/vocals_umxhq.onnx"
        );
        if !std::path::Path::new(path).is_file() {
            eprintln!("skip: {path} not present");
            return;
        }
        match Model::load_file(path) {
            Ok(model) => {
                eprintln!(
                    "vocal inputs={} outputs={} params={}",
                    model.input_ids().len(),
                    model.output_ids().len(),
                    model.total_params()
                );
                for (i, id) in model.input_ids().iter().enumerate() {
                    let info = model.node_info(*id).unwrap();
                    eprintln!("  in[{i}] {:?} {:?}", info.name(), info.shape());
                }
            }
            Err(err) => {
                eprintln!("vocal model did not load ({err}); Automix continues without a mask");
            }
        }
    }
}
