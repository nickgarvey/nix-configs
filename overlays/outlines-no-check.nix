# Overlay to disable tests for packages with sandbox issues
# - outlines: tests try to load llama-cpp-python which needs libcuda.so.1
# - rapidocr-onnxruntime: tests crash in sandbox (open-webui dependency)
final: prev: {
  python3Packages = prev.python3Packages.override {
    overrides = pfinal: pprev: {
      outlines = pprev.outlines.overridePythonAttrs (oldAttrs: {
        doCheck = false;
      });
      rapidocr-onnxruntime = pprev.rapidocr-onnxruntime.overridePythonAttrs (oldAttrs: {
        doCheck = false;
      });
    };
  };

  python313Packages = prev.python313Packages.override {
    overrides = pfinal: pprev: {
      outlines = pprev.outlines.overridePythonAttrs (oldAttrs: {
        doCheck = false;
      });
      rapidocr-onnxruntime = pprev.rapidocr-onnxruntime.overridePythonAttrs (oldAttrs: {
        doCheck = false;
      });
    };
  };
}


