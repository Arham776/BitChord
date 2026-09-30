use sha2::{Digest, Sha256};
fn main() {
    println!("cargo:rerun-if-changed=vendor/soxr-0.1.3");
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=Cargo.lock");
    println!("cargo:rerun-if-changed=Cargo.toml");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=../.git/HEAD");
    println!("cargo:rerun-if-changed=src/decode/apple_aac.c");
    let target = std::env::var("TARGET").unwrap();
    let mut cfg = cmake::Config::new("vendor/soxr-0.1.3");
    for key in [
        "BUILD_SHARED_LIBS",
        "BUILD_TESTS",
        "BUILD_EXAMPLES",
        "BUILD_LSR_TESTS",
        "WITH_OPENMP",
        "WITH_LSR_BINDINGS",
        "WITH_PFFFT",
        "WITH_CR32S",
        "WITH_CR64S",
    ] {
        cfg.define(key, "OFF");
    }
    // Match the application's minimum deployment targets for every slice.
    if target.contains("apple") {
        cfg.define(
            "CMAKE_OSX_DEPLOYMENT_TARGET",
            if target.contains("ios") {
                "18.0"
            } else {
                "15.0"
            },
        );
        if target.contains("ios") {
            let sdk = if target.contains("sim") {
                "iphonesimulator"
            } else {
                "iphoneos"
            };
            let output = std::process::Command::new("xcrun")
                .args(["--sdk", sdk, "--show-sdk-path"])
                .output()
                .expect("xcrun SDK");
            assert!(output.status.success());
            cfg.define("CMAKE_SYSTEM_NAME", "iOS");
            cfg.define(
                "CMAKE_OSX_SYSROOT",
                String::from_utf8(output.stdout).unwrap().trim(),
            );
            cfg.define("CMAKE_OSX_ARCHITECTURES", "arm64");
        }
    }
    cfg.define("CMAKE_POLICY_VERSION_MINIMUM", "3.5");
    let dst = cfg.build();
    println!("cargo:rustc-link-search=native={}/lib", dst.display());
    println!("cargo:rustc-link-lib=static=soxr");
    if target.contains("apple") {
        cc::Build::new()
            .file("src/decode/apple_aac.c")
            .flag("-fvisibility=hidden")
            .compile("bitchord_apple_aac");
        println!("cargo:rustc-link-lib=framework=AudioToolbox");
    }
    let revision = std::process::Command::new("git")
        .args(["rev-parse", "--short=12", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_else(|| "unknown".into());
    fn files(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
        for e in std::fs::read_dir(dir).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                files(&p, out);
            } else {
                out.push(p);
            }
        }
    }
    let mut paths = Vec::new();
    files(std::path::Path::new("src"), &mut paths);
    for path in ["Cargo.lock", "Cargo.toml", "build.rs"] {
        paths.push(path.into());
    }
    files(std::path::Path::new("vendor/soxr-0.1.3"), &mut paths);
    paths.sort();
    let mut hash = Sha256::new();
    for path in paths {
        hash.update(path.to_string_lossy().as_bytes());
        hash.update(std::fs::read(path).unwrap());
    }
    let digest = format!("{:x}", hash.finalize());
    println!(
        "cargo:rustc-env=BITCHORD_CORE_REVISION={revision}+{}",
        &digest[..12]
    );
}
