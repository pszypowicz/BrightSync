#ifndef CPRIVATE_APIS_H
#define CPRIVATE_APIS_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

/*
 * IOAVService: private API used to talk DDC/CI (I2C) to external displays
 * driven by the Apple Silicon DCP. The symbols are exported by
 * IOKit.framework and listed in the SDK tbd, so they resolve at link time.
 * Both creators follow the CF Create rule, hence CF_RETURNS_RETAINED.
 */
typedef CFTypeRef IOAVServiceRef;

CF_RETURNS_RETAINED IOAVServiceRef IOAVServiceCreate(CFAllocatorRef allocator);
CF_RETURNS_RETAINED IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t offset, void *outputBuffer, uint32_t outputBufferSize);
IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t dataAddress, void *inputBuffer, uint32_t inputBufferSize);

#endif
