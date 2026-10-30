/* Prueft die ONNX-Runtime-ABI gegen die generierte Zig-Bindung.
 *
 * Der Generator in gen_ort_api.py macht aus `struct OrtApi` eine flache
 * Folge von Funktionspointern. Jede Abweichung in Reihenfolge oder Zahl
 * verschiebt alle folgenden Funktionszeiger und faehrt still in die
 * Irre. Dieses Programm druckt Groesse und Offset jedes Members, damit
 * die Zig-Seite dagegen geprueft werden kann.
 *
 * Bauen und ausfuehren:
 *   cc -I <ort-include> verify_ort_abi.c -o verify_ort_abi
 *   ./verify_ort_abi > abi.txt
 */
#include <stddef.h>
#include <stdio.h>

#include "onnxruntime_c_api.h"

#define PRINT(member) printf("%s %zu\n", #member, offsetof(OrtApi, member))

int main(void) {
    printf("sizeof %zu\n", sizeof(OrtApi));
    PRINT(CreateStatus);
    PRINT(GetErrorCode);
    PRINT(GetErrorMessage);
    PRINT(CreateEnv);
    PRINT(CreateSession);
    PRINT(Run);
    PRINT(CreateSessionOptions);
    PRINT(SetSessionExecutionMode);
    PRINT(DisableProfiling);
    PRINT(SetSessionLogSeverityLevel);
    PRINT(SetSessionGraphOptimizationLevel);
    PRINT(SetIntraOpNumThreads);
    PRINT(SetInterOpNumThreads);
    PRINT(SessionGetInputCount);
    PRINT(SessionGetOutputCount);
    PRINT(SessionGetInputTypeInfo);
    PRINT(SessionGetOutputTypeInfo);
    PRINT(SessionGetInputName);
    PRINT(SessionGetOutputName);
    PRINT(CreateTensorWithDataAsOrtValue);
    PRINT(GetTensorMutableData);
    PRINT(CastTypeInfoToTensorInfo);
    PRINT(GetOnnxTypeFromTypeInfo);
    PRINT(GetTensorElementType);
    PRINT(GetDimensionsCount);
    PRINT(GetDimensions);
    PRINT(GetTensorShapeElementCount);
    PRINT(GetTensorTypeAndShape);
    PRINT(CreateCpuMemoryInfo);
    PRINT(AllocatorFree);
    PRINT(GetAllocatorWithDefaultOptions);
    PRINT(ReleaseEnv);
    PRINT(ReleaseStatus);
    PRINT(ReleaseMemoryInfo);
    PRINT(ReleaseSession);
    PRINT(ReleaseValue);
    PRINT(ReleaseTypeInfo);
    PRINT(ReleaseTensorTypeAndShapeInfo);
    PRINT(ReleaseSessionOptions);
    PRINT(ReleaseModelMetadata);
    PRINT(SessionGetModelMetadata);
    PRINT(ModelMetadataGetProducerName);
    PRINT(ModelMetadataGetGraphName);
    PRINT(ModelMetadataLookupCustomMetadataMap);
    PRINT(ModelMetadataGetCustomMetadataMapKeys);
    return 0;
}
