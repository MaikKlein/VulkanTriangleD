import erupted;

void enforceVk(VkResult res){
    import std.exception;
    import std.conv;
    enforce(res is VkResult.VK_SUCCESS, res.to!string);
}

extern(System) VkBool32 MyDebugReportCallback(
    VkDebugReportFlagsEXT       flags,
    VkDebugReportObjectTypeEXT  objectType,
    uint64_t                    object,
    size_t                      location,
    int32_t                     messageCode,
    const char*                 pLayerPrefix,
    const char*                 pMessage,
    void*                       pUserData) nothrow @nogc
{
    import std.stdio;
    printf("ObjectTpye: %i  \n", objectType);
    printf(pMessage);
    printf("\n");
    return VK_FALSE;
}

struct VkContext{
    VkInstance instance;
    VkSurfaceKHR surface;
    VkPhysicalDevice physicalDevice;
    VkDevice logicalDevice;
    ulong presentQueueFamilyIndex = -1;
    VkQueue presentQueue;
    uint width = -1;
    uint height = -1;
    VkSwapchainKHR swapchain;
    VkCommandBuffer setupCmdBuffer;
    VkCommandBuffer drawCmdBuffer;
    VkImage[] presentImages;
    VkImage depthImage;
    VkPhysicalDeviceMemoryProperties memoryProperties;
    VkImageView depthImageView;
    VkRenderPass renderPass;
    VkFramebuffer[] frameBuffers;
    VkBuffer vertexInputBuffer;
    VkPipelineLayout pipelineLayout;
    VkPipeline pipeline;
    VkSemaphore presentCompleteSemaphore, renderingCompleteSemaphore;
}

void main()
{
    import std.exception;
    import derelict.sdl2.sdl;
    import std.algorithm.searching;
    import std.algorithm.iteration;
    import std.range: iota;
    import std.stdio;
    import core.stdc.string;

    VkContext vkcontext;
    vkcontext.width = 800;
    vkcontext.height = 600;

    DerelictSDL2.load();
    auto sdlWindow = SDL_CreateWindow("vulkan", 0, 0, 800, 600, 0);
    SDL_SysWMinfo sdlWindowInfo;

    SDL_VERSION(&sdlWindowInfo.version_);
    enforce(SDL_GetWindowWMInfo(sdlWindow, &sdlWindowInfo), "sdl err");

    DerelictErupted.load();
    VkApplicationInfo appinfo;
    appinfo.pApplicationName = "Breeze";
    appinfo.apiVersion = VK_MAKE_VERSION(1, 0, 2);

    const(char*)[3] extensionNames = [
        "VK_KHR_surface",
        "VK_KHR_xlib_surface",
        "VK_EXT_debug_report"
    ];
    uint extensionCount = 0;
    vkEnumerateInstanceExtensionProperties(null, &extensionCount, null );

    auto extensionProps = new VkExtensionProperties[](extensionCount);
    vkEnumerateInstanceExtensionProperties(null, &extensionCount, extensionProps.ptr );

    enforce(extensionNames[].all!((extensionName){
        return extensionProps[].count!((extension){
            return strcmp(cast(const(char*))extension.extensionName, extensionName) == 0;
        }) > 0;
    }), "extension props failure");

    uint layerCount = 0;
    vkEnumerateInstanceLayerProperties(&layerCount, null);

    auto layerProps = new VkLayerProperties[](layerCount);
    vkEnumerateInstanceLayerProperties(&layerCount, layerProps.ptr);

    const(char*)[1] validationLayers = ["VK_LAYER_LUNARG_standard_validation"];

    enforce(validationLayers[].all!((layerName){
        return layerProps[].count!((layer){
            return strcmp(cast(const(char*))layer.layerName, layerName) == 0;
        }) > 0;
    }), "Validation layer failure");

    VkInstanceCreateInfo createinfo;
    createinfo.sType = VkStructureType.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    createinfo.pApplicationInfo = &appinfo;
    createinfo.enabledExtensionCount = cast(uint)extensionNames.length;
    createinfo.ppEnabledExtensionNames = extensionNames.ptr;
    createinfo.enabledLayerCount = validationLayers.length;
    createinfo.ppEnabledLayerNames = validationLayers.ptr;

    enforceVk(vkCreateInstance(&createinfo, null, &vkcontext.instance));

    loadInstanceLevelFunctions(vkcontext.instance);
    auto debugcallbackCreateInfo = VkDebugReportCallbackCreateInfoEXT(
        VkStructureType.VK_STRUCTURE_TYPE_DEBUG_REPORT_CALLBACK_CREATE_INFO_EXT,
        null,
        VkDebugReportFlagBitsEXT.VK_DEBUG_REPORT_ERROR_BIT_EXT |
        VkDebugReportFlagBitsEXT.VK_DEBUG_REPORT_WARNING_BIT_EXT |
        VkDebugReportFlagBitsEXT.VK_DEBUG_REPORT_PERFORMANCE_WARNING_BIT_EXT,
        &MyDebugReportCallback,
        null
    );
    VkDebugReportCallbackEXT callback;
    enforceVk(vkCreateDebugReportCallbackEXT(vkcontext.instance, &debugcallbackCreateInfo, null, &callback));

    auto xlibInfo = VkXlibSurfaceCreateInfoKHR(
        VkStructureType.VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR,
        null,
        0,
        sdlWindowInfo.info.x11.display,
        sdlWindowInfo.info.x11.window
    );
    enforceVk(vkCreateXlibSurfaceKHR(vkcontext.instance, &xlibInfo, null, &vkcontext.surface));

    uint numOfDevices;
    enforceVk(vkEnumeratePhysicalDevices(vkcontext.instance, &numOfDevices, null));

    auto devices = new VkPhysicalDevice[](numOfDevices);
    enforceVk(vkEnumeratePhysicalDevices(vkcontext.instance, &numOfDevices, devices.ptr));

    const(char*)[1] deviceExtensions = ["VK_KHR_swapchain"];

    foreach(index, device; devices){
        VkPhysicalDeviceProperties props;

        vkGetPhysicalDeviceProperties(device, &props);
        if(
           props.deviceType is VkPhysicalDeviceType.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU || 
           props.deviceType is VkPhysicalDeviceType.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
           ){
            uint queueCount = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(device, &queueCount, null);
            enforce(queueCount > 0);
            auto queueFamilyProp = new VkQueueFamilyProperties[](queueCount);
            vkGetPhysicalDeviceQueueFamilyProperties(device, &queueCount, queueFamilyProp.ptr);

            auto presentIndex = queueFamilyProp[].countUntil!((prop){
                return prop.queueCount > 0 && (prop.queueFlags & VkQueueFlagBits.VK_QUEUE_GRAPHICS_BIT);
            });

            VkBool32 supportsPresent;
            vkGetPhysicalDeviceSurfaceSupportKHR(
                device, cast(uint)presentIndex,
                vkcontext.surface, &supportsPresent
            );

            if(presentIndex !is -1 && supportsPresent){
                vkcontext.presentQueueFamilyIndex = presentIndex;
                vkcontext.physicalDevice = device;
                break;
            }
        }
    }

    enforce(
        vkcontext.presentQueueFamilyIndex !is -1 &&
        vkcontext.physicalDevice,
        "Could not find a suitable device"
    );

    uint extensionDeviceCount = 0;
    vkEnumerateDeviceExtensionProperties(vkcontext.physicalDevice, null, &extensionDeviceCount, null);
    auto extensionDeviceProps = new VkExtensionProperties[](extensionDeviceCount);

    vkEnumerateDeviceExtensionProperties(vkcontext.physicalDevice, null, &extensionDeviceCount, extensionDeviceProps.ptr);

    enforce(vkcontext.physicalDevice != null, "Device is null");
    //enforce the swapchain
    enforce(extensionDeviceProps[].map!(prop => prop.extensionName).count!((name){
                return strcmp(cast(const(char*))name, "VK_KHR_swapchain" ) == 0;
    }) > 0);

    float[1] priorities = [1.0f];
    VkDeviceQueueCreateInfo deviceQueueCreateInfo =
        VkDeviceQueueCreateInfo(
            VkStructureType.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            null,
            0,
            cast(uint)vkcontext.presentQueueFamilyIndex,
            cast(uint)priorities.length,
            priorities.ptr
    );

    VkPhysicalDeviceFeatures features;
    features.shaderClipDistance = VK_TRUE;

    auto deviceInfo = VkDeviceCreateInfo(
        VkStructureType.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        null,
        0,
        1,
        &deviceQueueCreateInfo,
        validationLayers.length,
        validationLayers.ptr,
        cast(uint)deviceExtensions.length,
        deviceExtensions.ptr,
        &features
    );
    enforceVk(vkCreateDevice(vkcontext.physicalDevice, &deviceInfo, null, &vkcontext.logicalDevice));

    loadDeviceLevelFunctions(vkcontext.logicalDevice);
    VkQueue queue;
    vkGetDeviceQueue(vkcontext.logicalDevice, cast(uint)vkcontext.presentQueueFamilyIndex, 0, &vkcontext.presentQueue);

    uint formatCount = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(vkcontext.physicalDevice, vkcontext.surface, &formatCount, null);
    enforce(formatCount > 0, "Format failed");
    auto surfaceFormats = new VkSurfaceFormatKHR[](formatCount);
    vkGetPhysicalDeviceSurfaceFormatsKHR(vkcontext.physicalDevice, vkcontext.surface, &formatCount, surfaceFormats.ptr);

    VkFormat colorFormat;
    if(surfaceFormats[0].format is VK_FORMAT_UNDEFINED){
        colorFormat = VK_FORMAT_B8G8R8_UNORM;
    }
    else{
        colorFormat = surfaceFormats[0].format;
    }

    VkColorSpaceKHR colorSpace;
    colorSpace = surfaceFormats[0].colorSpace;

    VkSurfaceCapabilitiesKHR surfaceCapabilities;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(vkcontext.physicalDevice, vkcontext.surface, &surfaceCapabilities);

    uint desiredImageCount = 2;
    if( desiredImageCount < surfaceCapabilities.minImageCount ) {
        desiredImageCount = surfaceCapabilities.minImageCount;
    }
    else if(surfaceCapabilities.maxImageCount != 0 &&
                    desiredImageCount > surfaceCapabilities.maxImageCount ) {
        desiredImageCount = surfaceCapabilities.maxImageCount;
    }

    VkExtent2D surfaceResolution = surfaceCapabilities.currentExtent;

    if(surfaceResolution.width is -1){
        surfaceResolution.width = vkcontext.width;
        surfaceResolution.height = vkcontext.height;
    }
    else{
        vkcontext.width = surfaceResolution.width;
        vkcontext.height = surfaceResolution.height;
    }

    VkSurfaceTransformFlagBitsKHR preTransform = surfaceCapabilities.currentTransform;
    if(surfaceCapabilities.supportedTransforms & VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR){
        preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    }

    uint presentModeCount = 0;
    vkGetPhysicalDeviceSurfacePresentModesKHR(vkcontext.physicalDevice, vkcontext.surface, &presentModeCount, null);
    auto presentModes = new VkPresentModeKHR[](presentModeCount);
    vkGetPhysicalDeviceSurfacePresentModesKHR(vkcontext.physicalDevice, vkcontext.surface, &presentModeCount, presentModes.ptr);

    VkPresentModeKHR presentMode = VK_PRESENT_MODE_FIFO_KHR;
    foreach(mode; presentModes){
        if(mode is VK_PRESENT_MODE_MAILBOX_KHR){
            presentMode = mode;
            break;
        }
    }

    VkSwapchainCreateInfoKHR swapchainCreateInfo;
    swapchainCreateInfo.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    swapchainCreateInfo.surface = vkcontext.surface;
    swapchainCreateInfo.imageFormat = colorFormat;
    swapchainCreateInfo.minImageCount = desiredImageCount;
    swapchainCreateInfo.imageColorSpace = colorSpace;
    swapchainCreateInfo.imageExtent = surfaceResolution;
    swapchainCreateInfo.imageArrayLayers = 1;
    swapchainCreateInfo.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    swapchainCreateInfo.imageSharingMode = VkSharingMode.VK_SHARING_MODE_EXCLUSIVE;
    swapchainCreateInfo.preTransform = preTransform;
    swapchainCreateInfo.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    swapchainCreateInfo.presentMode = presentMode;
    swapchainCreateInfo.clipped = VK_TRUE;
    swapchainCreateInfo.oldSwapchain = null;

    enforceVk(vkCreateSwapchainKHR(vkcontext.logicalDevice, &swapchainCreateInfo, null, &vkcontext.swapchain));

    VkCommandPoolCreateInfo commandPoolCreateInfo;
    commandPoolCreateInfo.sType = VkStructureType.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    commandPoolCreateInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    commandPoolCreateInfo.queueFamilyIndex = cast(uint)vkcontext.presentQueueFamilyIndex;

    VkCommandPool commandPool;
    enforceVk(vkCreateCommandPool(vkcontext.logicalDevice, &commandPoolCreateInfo, null, &commandPool));

    VkCommandBufferAllocateInfo cmdBufferAllocateInfo;
    cmdBufferAllocateInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cmdBufferAllocateInfo.commandPool = commandPool;
    cmdBufferAllocateInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cmdBufferAllocateInfo.commandBufferCount = 1;

    enforceVk(vkAllocateCommandBuffers(vkcontext.logicalDevice, &cmdBufferAllocateInfo, &vkcontext.setupCmdBuffer));
    enforceVk(vkAllocateCommandBuffers(vkcontext.logicalDevice, &cmdBufferAllocateInfo, &vkcontext.drawCmdBuffer));


    uint imageCount = 0;
    vkGetSwapchainImagesKHR(vkcontext.logicalDevice, vkcontext.swapchain, &imageCount, null);
    vkcontext.presentImages = new VkImage[](imageCount);
    enforceVk(vkGetSwapchainImagesKHR(vkcontext.logicalDevice, vkcontext.swapchain, &imageCount, vkcontext.presentImages.ptr));

    VkImageViewCreateInfo imgViewCreateInfo;
    imgViewCreateInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    imgViewCreateInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
    imgViewCreateInfo.format = colorFormat;
    imgViewCreateInfo.components =
        VkComponentMapping(
            VK_COMPONENT_SWIZZLE_R,
            VK_COMPONENT_SWIZZLE_G,
            VK_COMPONENT_SWIZZLE_B,
            VK_COMPONENT_SWIZZLE_A,
    );

    imgViewCreateInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    imgViewCreateInfo.subresourceRange.baseMipLevel = 0;
    imgViewCreateInfo.subresourceRange.levelCount = 1;
    imgViewCreateInfo.subresourceRange.baseArrayLayer = 0;
    imgViewCreateInfo.subresourceRange.layerCount = 1;

    VkCommandBufferBeginInfo beginInfo;
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    VkFenceCreateInfo fenceCreateInfo;
    fenceCreateInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;

    VkFence submitFence;
    vkCreateFence(vkcontext.logicalDevice, &fenceCreateInfo, null, &submitFence);

    auto presentImageViews = new VkImageView[](imageCount);
    foreach(index; iota(0, imageCount)){
        imgViewCreateInfo.image = vkcontext.presentImages[index];
        enforceVk(vkCreateImageView(vkcontext.logicalDevice, &imgViewCreateInfo, null, &presentImageViews[index]));
    }

    vkGetPhysicalDeviceMemoryProperties(vkcontext.physicalDevice, &vkcontext.memoryProperties);

    VkImageCreateInfo imageCreateInfo;
    imageCreateInfo.imageType = VK_IMAGE_TYPE_2D;
    imageCreateInfo.format = VK_FORMAT_D16_UNORM;
    imageCreateInfo.extent = VkExtent3D(vkcontext.width, vkcontext.height, 1);
    imageCreateInfo.mipLevels = 1;
    imageCreateInfo.arrayLayers = 1;
    imageCreateInfo.samples = VK_SAMPLE_COUNT_1_BIT;
    imageCreateInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
    imageCreateInfo.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    imageCreateInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    imageCreateInfo.queueFamilyIndexCount = 0;
    imageCreateInfo.pQueueFamilyIndices = null;
    imageCreateInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

    enforceVk(vkCreateImage(vkcontext.logicalDevice, &imageCreateInfo, null, &vkcontext.depthImage));

    VkMemoryRequirements memoryRequirements;
    vkGetImageMemoryRequirements(vkcontext.logicalDevice, vkcontext.depthImage, &memoryRequirements);

    VkMemoryAllocateInfo imageAllocationInfo;
    imageAllocationInfo.allocationSize = memoryRequirements.size;

    uint memoryTypeBits = memoryRequirements.memoryTypeBits;
    VkMemoryPropertyFlags desiredMemoryFlags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;

    foreach(index; iota(0, 32)){
        VkMemoryType memoryType = vkcontext.memoryProperties.memoryTypes[index];
        if(memoryTypeBits & 1){
            if((memoryType.propertyFlags & desiredMemoryFlags) is desiredMemoryFlags){
                imageAllocationInfo.memoryTypeIndex = index;
                break;
            }
        }
        memoryTypeBits = memoryTypeBits >> 1;
    }

    VkDeviceMemory imageMemory;
    enforceVk(vkAllocateMemory(vkcontext.logicalDevice, &imageAllocationInfo, null, &imageMemory));

    enforceVk(vkBindImageMemory(vkcontext.logicalDevice, vkcontext.depthImage, imageMemory, 0));

    vkBeginCommandBuffer(vkcontext.setupCmdBuffer, &beginInfo);
    VkImageMemoryBarrier layoutTransitionBarrier;
    layoutTransitionBarrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    layoutTransitionBarrier.srcAccessMask = 0;
    layoutTransitionBarrier.dstAccessMask = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT |
                                                                                    VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
    layoutTransitionBarrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    layoutTransitionBarrier.newLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    layoutTransitionBarrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    layoutTransitionBarrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    layoutTransitionBarrier.image = vkcontext.depthImage;
    layoutTransitionBarrier.subresourceRange = VkImageSubresourceRange(VK_IMAGE_ASPECT_DEPTH_BIT, 0, 1, 0, 1);

    vkCmdPipelineBarrier(
        vkcontext.setupCmdBuffer,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        0,
        0, null,
        0, null,
        1, &layoutTransitionBarrier
    );

    vkEndCommandBuffer(vkcontext.setupCmdBuffer);

    VkPipelineStageFlags[1] waitStageMask = [ VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT ];
    VkSubmitInfo submitInfo;
    submitInfo.waitSemaphoreCount = 0;
    submitInfo.pWaitSemaphores = null;
    submitInfo.pWaitDstStageMask = waitStageMask.ptr;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &vkcontext.setupCmdBuffer;
    submitInfo.signalSemaphoreCount = 0;
    submitInfo.pSignalSemaphores = null;

    vkQueueSubmit(vkcontext.presentQueue, 1, &submitInfo, submitFence);

    vkWaitForFences(vkcontext.logicalDevice, 1, &submitFence, VK_TRUE, ulong.max);
    vkResetFences(vkcontext.logicalDevice, 1, &submitFence);
    vkResetCommandBuffer(vkcontext.setupCmdBuffer, 0);

    VkImageAspectFlags aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
    VkImageViewCreateInfo imageViewCreateInfo;
    imageViewCreateInfo.image = vkcontext.depthImage;
    imageViewCreateInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
    imageViewCreateInfo.format = imageCreateInfo.format;
    imageViewCreateInfo.components =
        VkComponentMapping(VK_COMPONENT_SWIZZLE_IDENTITY,
            VK_COMPONENT_SWIZZLE_IDENTITY,
            VK_COMPONENT_SWIZZLE_IDENTITY,
            VK_COMPONENT_SWIZZLE_IDENTITY
    );
    imageViewCreateInfo.subresourceRange.aspectMask = aspectMask;
    imageViewCreateInfo.subresourceRange.baseMipLevel = 0;
    imageViewCreateInfo.subresourceRange.levelCount = 1;
    imageViewCreateInfo.subresourceRange.baseArrayLayer = 0;
    imageViewCreateInfo.subresourceRange.layerCount = 1;

    enforceVk(vkCreateImageView(vkcontext.logicalDevice, &imageViewCreateInfo, null, &vkcontext.depthImageView));

    VkAttachmentDescription[2] passAttachments;
    passAttachments[0].format = colorFormat;
    passAttachments[0].samples = VK_SAMPLE_COUNT_1_BIT;
    passAttachments[0].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    passAttachments[0].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    passAttachments[0].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    passAttachments[0].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    passAttachments[0].initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    passAttachments[0].finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    passAttachments[1].format = VK_FORMAT_D16_UNORM;
    passAttachments[1].samples = VK_SAMPLE_COUNT_1_BIT;
    passAttachments[1].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    passAttachments[1].storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    passAttachments[1].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    passAttachments[1].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    passAttachments[1].initialLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    passAttachments[1].finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

    VkAttachmentReference colorAttachmentReference;
    colorAttachmentReference.attachment = 0;
    colorAttachmentReference.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    VkAttachmentReference depthAttachmentReference;
    depthAttachmentReference.attachment = 1;
    depthAttachmentReference.layout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

    VkSubpassDescription subpass;
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &colorAttachmentReference;
    subpass.pDepthStencilAttachment = &depthAttachmentReference;

    VkRenderPassCreateInfo renderPassCreateInfo;
    renderPassCreateInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    renderPassCreateInfo.attachmentCount = 2;
    renderPassCreateInfo.pAttachments = passAttachments.ptr;
    renderPassCreateInfo.subpassCount = 1;
    renderPassCreateInfo.pSubpasses = &subpass;

    enforceVk(vkCreateRenderPass(vkcontext.logicalDevice, &renderPassCreateInfo, null, &vkcontext.renderPass));

    VkImageView[2] frameBufferAttachments;
    frameBufferAttachments[1] = vkcontext.depthImageView;

    VkFramebufferCreateInfo frameBufferCreateInfo;
    frameBufferCreateInfo.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    frameBufferCreateInfo.renderPass = vkcontext.renderPass;
    frameBufferCreateInfo.attachmentCount = 2;
    frameBufferCreateInfo.pAttachments = frameBufferAttachments.ptr;
    frameBufferCreateInfo.width = vkcontext.width;
    frameBufferCreateInfo.height = vkcontext.height;
    frameBufferCreateInfo.layers = 1;

    vkcontext.frameBuffers = new VkFramebuffer[](imageCount);
    foreach(index; iota(0, imageCount)){
        frameBufferAttachments[0] = presentImageViews[index];
        enforceVk(vkCreateFramebuffer(vkcontext.logicalDevice, &frameBufferCreateInfo, null, &vkcontext.frameBuffers[index]));
    }

    struct Vertex{
        float x, y, z, w;
    }

    VkBufferCreateInfo vertexInputBufferInfo;
    vertexInputBufferInfo.size = Vertex.sizeof * 3;
    vertexInputBufferInfo.usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
    vertexInputBufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

    enforceVk(vkCreateBuffer(vkcontext.logicalDevice, &vertexInputBufferInfo, null, &vkcontext.vertexInputBuffer));

    VkMemoryRequirements vertexBufferMemoryReq;
    vkGetBufferMemoryRequirements(vkcontext.logicalDevice, vkcontext.vertexInputBuffer, &vertexBufferMemoryReq);

    VkMemoryAllocateInfo bufferAllocateInfo;
    bufferAllocateInfo.allocationSize = vertexBufferMemoryReq.size;

    uint vertexMemoryTypeBits = vertexBufferMemoryReq.memoryTypeBits;
    VkMemoryPropertyFlags vertexDesiredMemoryFlags = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;

    foreach(index; iota(0, 32)){
        VkMemoryType memoryType = vkcontext.memoryProperties.memoryTypes[index];
        if(vertexMemoryTypeBits & 1){
            if((memoryType.propertyFlags & vertexDesiredMemoryFlags) is vertexDesiredMemoryFlags){
                bufferAllocateInfo.memoryTypeIndex = index;
                break;
            }
        }
        vertexMemoryTypeBits = vertexMemoryTypeBits >> 1;
    }

    VkDeviceMemory vertexBufferMemory;
    enforceVk(vkAllocateMemory(vkcontext.logicalDevice, &bufferAllocateInfo, null, &vertexBufferMemory));

    void* mapped;
    enforceVk(vkMapMemory(vkcontext.logicalDevice, vertexBufferMemory, 0, VK_WHOLE_SIZE, 0, &mapped));

    Vertex[] triangle = (cast(Vertex*)mapped)[0 .. 3];
    triangle[0] = Vertex(-1.0f, 1.0f, 0.0f, 1.0f);
    triangle[1] = Vertex(1.0f, 1.0f, 0.0f, 1.0f);
    triangle[2] = Vertex(0.0f, -1.0f, 0.0f, 1.0f);

    vkUnmapMemory(vkcontext.logicalDevice, vertexBufferMemory );
    enforceVk(vkBindBufferMemory(vkcontext.logicalDevice, vkcontext.vertexInputBuffer, vertexBufferMemory, 0));

    auto vertFile = File("vert.spv", "r");
    auto fragFile = File("frag.spv", "r");

    char[] vertCode = new char[](vertFile.size);
    auto vertCodeSlice = vertFile.rawRead(vertCode);

    char[] fragCode = new char[](fragFile.size);
    auto fragCodeSlice = fragFile.rawRead(fragCode);

    VkShaderModuleCreateInfo vertexShaderCreateInfo;
    vertexShaderCreateInfo.codeSize = vertCodeSlice.length;
    vertexShaderCreateInfo.pCode = cast(uint*)vertCodeSlice.ptr;

    VkShaderModuleCreateInfo fragmentShaderCreateInfo;
    fragmentShaderCreateInfo.codeSize = fragCodeSlice.length;
    fragmentShaderCreateInfo.pCode = cast(uint*)fragCodeSlice.ptr;

    VkShaderModule vertexShaderModule;
    enforceVk(vkCreateShaderModule(vkcontext.logicalDevice, &vertexShaderCreateInfo, null, &vertexShaderModule));

    VkShaderModule fragmentShaderModule;
    enforceVk(vkCreateShaderModule(vkcontext.logicalDevice, &fragmentShaderCreateInfo, null, &fragmentShaderModule));

    VkPipelineLayoutCreateInfo layoutCreateInfo;
    layoutCreateInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    layoutCreateInfo.setLayoutCount = 0;
    layoutCreateInfo.pSetLayouts = null;        // Not setting any bindings!
    layoutCreateInfo.pushConstantRangeCount = 0;
    layoutCreateInfo.pPushConstantRanges = null;

    enforceVk(vkCreatePipelineLayout(vkcontext.logicalDevice, &layoutCreateInfo, null, &vkcontext.pipelineLayout));

    VkPipelineShaderStageCreateInfo[2] shaderStageCreateInfo;
    shaderStageCreateInfo[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    shaderStageCreateInfo[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    shaderStageCreateInfo[0]._module = vertexShaderModule;
    shaderStageCreateInfo[0].pName = "main";                // shader entry point function name
    shaderStageCreateInfo[0].pSpecializationInfo = null;

    shaderStageCreateInfo[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    shaderStageCreateInfo[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    shaderStageCreateInfo[1]._module = fragmentShaderModule;
    shaderStageCreateInfo[1].pName = "main";                // shader entry point function name
    shaderStageCreateInfo[1].pSpecializationInfo = null;

    VkVertexInputBindingDescription vertexBindingDescription = {};
    vertexBindingDescription.binding = 0;
    vertexBindingDescription.stride = Vertex.sizeof;
    vertexBindingDescription.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;

    VkVertexInputAttributeDescription vertexAttributeDescritpion = {};
    vertexAttributeDescritpion.location = 0;
    vertexAttributeDescritpion.binding = 0;
    vertexAttributeDescritpion.format = VK_FORMAT_R32G32B32A32_SFLOAT;
    vertexAttributeDescritpion.offset = 0;

    VkPipelineVertexInputStateCreateInfo vertexInputStateCreateInfo = {};
    vertexInputStateCreateInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vertexInputStateCreateInfo.vertexBindingDescriptionCount = 1;
    vertexInputStateCreateInfo.pVertexBindingDescriptions = &vertexBindingDescription;
    vertexInputStateCreateInfo.vertexAttributeDescriptionCount = 1;
    vertexInputStateCreateInfo.pVertexAttributeDescriptions = &vertexAttributeDescritpion;

    VkPipelineInputAssemblyStateCreateInfo inputAssemblyStateCreateInfo = {};
    inputAssemblyStateCreateInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    inputAssemblyStateCreateInfo.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    inputAssemblyStateCreateInfo.primitiveRestartEnable = VK_FALSE;

    VkViewport viewport = {};
    viewport.x = 0;
    viewport.y = 0;
    viewport.width = vkcontext.width;
    viewport.height = vkcontext.height;
    viewport.minDepth = 0;
    viewport.maxDepth = 1;

    VkRect2D scissors;
    scissors.offset = VkOffset2D( 0, 0 );
    scissors.extent = VkExtent2D( vkcontext.width, vkcontext.height );

    VkPipelineViewportStateCreateInfo viewportState;
    viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewportState.viewportCount = 1;
    viewportState.pViewports = &viewport;
    viewportState.scissorCount = 1;
    viewportState.pScissors = &scissors;


    VkPipelineRasterizationStateCreateInfo rasterizationState;
    rasterizationState.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterizationState.depthClampEnable = VK_FALSE;
    rasterizationState.rasterizerDiscardEnable = VK_FALSE;
    rasterizationState.polygonMode = VK_POLYGON_MODE_FILL;
    rasterizationState.cullMode = VK_CULL_MODE_NONE;
    rasterizationState.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    rasterizationState.depthBiasEnable = VK_FALSE;
    rasterizationState.depthBiasConstantFactor = 0;
    rasterizationState.depthBiasClamp = 0;
    rasterizationState.depthBiasSlopeFactor = 0;
    rasterizationState.lineWidth = 1;

    VkPipelineMultisampleStateCreateInfo multisampleState;
    multisampleState.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisampleState.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    multisampleState.sampleShadingEnable = VK_FALSE;
    multisampleState.minSampleShading = 0;
    multisampleState.pSampleMask = null;
    multisampleState.alphaToCoverageEnable = VK_FALSE;
    multisampleState.alphaToOneEnable = VK_FALSE;

    VkStencilOpState noOPStencilState = {};
    noOPStencilState.failOp = VK_STENCIL_OP_KEEP;
    noOPStencilState.passOp = VK_STENCIL_OP_KEEP;
    noOPStencilState.depthFailOp = VK_STENCIL_OP_KEEP;
    noOPStencilState.compareOp = VK_COMPARE_OP_ALWAYS;
    noOPStencilState.compareMask = 0;
    noOPStencilState.writeMask = 0;
    noOPStencilState.reference = 0;

    VkPipelineDepthStencilStateCreateInfo depthState;
    depthState.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    depthState.depthTestEnable = VK_TRUE;
    depthState.depthWriteEnable = VK_TRUE;
    depthState.depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL;
    depthState.depthBoundsTestEnable = VK_FALSE;
    depthState.stencilTestEnable = VK_FALSE;
    depthState.front = noOPStencilState;
    depthState.back = noOPStencilState;
    depthState.minDepthBounds = 0;
    depthState.maxDepthBounds = 0;

    VkPipelineColorBlendAttachmentState colorBlendAttachmentState = {};
    colorBlendAttachmentState.blendEnable = VK_FALSE;
    colorBlendAttachmentState.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_COLOR;
    colorBlendAttachmentState.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR;
    colorBlendAttachmentState.colorBlendOp = VK_BLEND_OP_ADD;
    colorBlendAttachmentState.srcAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
    colorBlendAttachmentState.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
    colorBlendAttachmentState.alphaBlendOp = VK_BLEND_OP_ADD;
    colorBlendAttachmentState.colorWriteMask = 0xf;

    VkPipelineColorBlendStateCreateInfo colorBlendState = {};
    colorBlendState.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    colorBlendState.logicOpEnable = VK_FALSE;
    colorBlendState.logicOp = VK_LOGIC_OP_CLEAR;
    colorBlendState.attachmentCount = 1;
    colorBlendState.pAttachments = &colorBlendAttachmentState;
    colorBlendState.blendConstants[0] = 0.0;
    colorBlendState.blendConstants[1] = 0.0;
    colorBlendState.blendConstants[2] = 0.0;
    colorBlendState.blendConstants[3] = 0.0;

    VkDynamicState[2] dynamicState = [ VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR ];
    VkPipelineDynamicStateCreateInfo dynamicStateCreateInfo;
    dynamicStateCreateInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamicStateCreateInfo.dynamicStateCount = 2;
    dynamicStateCreateInfo.pDynamicStates = dynamicState.ptr;

    VkGraphicsPipelineCreateInfo pipelineCreateInfo = {};
    pipelineCreateInfo.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipelineCreateInfo.stageCount = 2;
    pipelineCreateInfo.pStages = shaderStageCreateInfo.ptr;
    pipelineCreateInfo.pVertexInputState = &vertexInputStateCreateInfo;
    pipelineCreateInfo.pInputAssemblyState = &inputAssemblyStateCreateInfo;
    pipelineCreateInfo.pTessellationState = null;
    pipelineCreateInfo.pViewportState = &viewportState;
    pipelineCreateInfo.pRasterizationState = &rasterizationState;
    pipelineCreateInfo.pMultisampleState = &multisampleState;
    pipelineCreateInfo.pDepthStencilState = &depthState;
    pipelineCreateInfo.pColorBlendState = &colorBlendState;
    pipelineCreateInfo.pDynamicState = &dynamicStateCreateInfo;
    pipelineCreateInfo.layout = vkcontext.pipelineLayout;
    pipelineCreateInfo.renderPass = vkcontext.renderPass;
    pipelineCreateInfo.subpass = 0;
    pipelineCreateInfo.basePipelineHandle = null;
    pipelineCreateInfo.basePipelineIndex = 0;

    enforceVk(vkCreateGraphicsPipelines(vkcontext.logicalDevice, null, 1, &pipelineCreateInfo, null, &vkcontext.pipeline));

    auto semaphoreCreateInfo = VkSemaphoreCreateInfo( VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, null, 0 );
    vkCreateSemaphore( vkcontext.logicalDevice, &semaphoreCreateInfo, null, &vkcontext.presentCompleteSemaphore );
    vkCreateSemaphore( vkcontext.logicalDevice, &semaphoreCreateInfo, null, &vkcontext.renderingCompleteSemaphore );

    //Render
    bool shouldClose = false;
    while(!shouldClose){
        SDL_Event event;
        while(SDL_PollEvent(&event)){
            if(event.type is SDL_QUIT){
                shouldClose = true;
            }
        }

        uint32_t nextImageIdx;
        vkAcquireNextImageKHR(
            vkcontext.logicalDevice, vkcontext.swapchain, ulong.max,
            vkcontext.presentCompleteSemaphore, null, &nextImageIdx
        );

        vkBeginCommandBuffer( vkcontext.drawCmdBuffer, &beginInfo );

        VkImageMemoryBarrier layoutToColorTrans;
        layoutToColorTrans.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        layoutToColorTrans.srcAccessMask = 0;
        layoutToColorTrans.dstAccessMask = 
            VK_ACCESS_COLOR_ATTACHMENT_READ_BIT |
            VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        layoutToColorTrans.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        layoutToColorTrans.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        layoutToColorTrans.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        layoutToColorTrans.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        layoutToColorTrans.image = vkcontext.presentImages[ nextImageIdx ];
        auto resourceRange = VkImageSubresourceRange( VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 );
        layoutToColorTrans.subresourceRange = resourceRange;

        vkCmdPipelineBarrier(
            vkcontext.drawCmdBuffer,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            0,
            0, null,
            0, null,
            1, &layoutToColorTrans
        );
        VkClearColorValue clearColorValue;
        clearColorValue.float32[0] = 1.0f;
        clearColorValue.float32[1] = 1.0f;
        clearColorValue.float32[2] = 1.0f;
        clearColorValue.float32[3] = 1.0f;

        VkClearValue firstclearValue;
        firstclearValue.color = clearColorValue;

        VkClearValue secondclearValue;
        secondclearValue.depthStencil = VkClearDepthStencilValue(1.0, 0);

        VkClearValue[2] clearValue = [ firstclearValue, secondclearValue ];

        VkRenderPassBeginInfo renderPassBeginInfo;
        renderPassBeginInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        renderPassBeginInfo.renderPass = vkcontext.renderPass;
        renderPassBeginInfo.framebuffer = vkcontext.frameBuffers[ nextImageIdx ];
        renderPassBeginInfo.renderArea = VkRect2D(VkOffset2D(0, 0), VkExtent2D(vkcontext.width, vkcontext.height));
        renderPassBeginInfo.clearValueCount = 2;
        renderPassBeginInfo.pClearValues = clearValue.ptr;

        vkCmdBeginRenderPass(
            vkcontext.drawCmdBuffer, &renderPassBeginInfo,
            VK_SUBPASS_CONTENTS_INLINE
        );

        vkCmdBindPipeline(vkcontext.drawCmdBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, vkcontext.pipeline);
        vkCmdSetViewport(vkcontext.drawCmdBuffer, 0, 1, &viewport);
        vkCmdSetScissor(vkcontext.drawCmdBuffer, 0 ,1, &scissors);

        VkDeviceSize offsets;
        vkCmdBindVertexBuffers( vkcontext.drawCmdBuffer, 0, 1, &vkcontext.vertexInputBuffer, &offsets );
        vkCmdDraw( vkcontext.drawCmdBuffer, 3, 1, 0, 0 );
        vkCmdEndRenderPass( vkcontext.drawCmdBuffer );

        VkImageMemoryBarrier prePresentBarrier;
        prePresentBarrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        prePresentBarrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        prePresentBarrier.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT;
        prePresentBarrier.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        prePresentBarrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        prePresentBarrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        prePresentBarrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        prePresentBarrier.subresourceRange = resourceRange;
        prePresentBarrier.image = vkcontext.presentImages[ nextImageIdx ];

        vkCmdPipelineBarrier(
            vkcontext.drawCmdBuffer,
            VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
            VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            0,
            0, null,
            0, null,
            1, &prePresentBarrier
        );

        vkEndCommandBuffer( vkcontext.drawCmdBuffer );

        VkPipelineStageFlags[1] waitRenderMask = [ VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT ];
        VkSubmitInfo renderSubmitInfo;
        renderSubmitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        renderSubmitInfo.waitSemaphoreCount = 1;
        renderSubmitInfo.pWaitSemaphores = &vkcontext.presentCompleteSemaphore;
        renderSubmitInfo.pWaitDstStageMask = waitRenderMask.ptr;
        renderSubmitInfo.commandBufferCount = 1;
        renderSubmitInfo.pCommandBuffers = &vkcontext.drawCmdBuffer;
        renderSubmitInfo.signalSemaphoreCount = 1;
        renderSubmitInfo.pSignalSemaphores = &vkcontext.renderingCompleteSemaphore;
        vkQueueSubmit( vkcontext.presentQueue, 1, &renderSubmitInfo, null );
        vkQueueWaitIdle(vkcontext.presentQueue);

        VkPresentInfoKHR presentInfo;
        presentInfo.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        presentInfo.pNext = null;
        presentInfo.waitSemaphoreCount = 1;
        presentInfo.pWaitSemaphores = &vkcontext.renderingCompleteSemaphore;
        presentInfo.swapchainCount = 1;
        presentInfo.pSwapchains = &vkcontext.swapchain;
        presentInfo.pImageIndices = &nextImageIdx;
        presentInfo.pResults = null;
        vkQueuePresentKHR( vkcontext.presentQueue, &presentInfo );
        vkQueueWaitIdle(vkcontext.presentQueue);
    }

    vkDestroyFence(vkcontext.logicalDevice, submitFence, null);

    vkFreeMemory(vkcontext.logicalDevice, vertexBufferMemory, null);
    vkDestroyBuffer(vkcontext.logicalDevice, vkcontext.vertexInputBuffer, null);
    vkDestroyPipeline(vkcontext.logicalDevice, vkcontext.pipeline, null);
    vkDestroyPipelineLayout(vkcontext.logicalDevice, vkcontext.pipelineLayout, null);
    vkDestroyRenderPass(vkcontext.logicalDevice, vkcontext.renderPass, null);

    foreach(ref framebuffer; vkcontext.frameBuffers){
        vkDestroyFramebuffer(vkcontext.logicalDevice, framebuffer, null);
    }

    vkDestroyShaderModule(vkcontext.logicalDevice, fragmentShaderModule, null);
    vkDestroyShaderModule(vkcontext.logicalDevice, vertexShaderModule, null);

    vkDestroyImageView(vkcontext.logicalDevice, vkcontext.depthImageView, null);
    vkDestroyImage(vkcontext.logicalDevice, vkcontext.depthImage, null);
    vkFreeMemory(vkcontext.logicalDevice, imageMemory, null);

    vkFreeCommandBuffers(vkcontext.logicalDevice, commandPool, 1, &vkcontext.drawCmdBuffer);
    vkFreeCommandBuffers(vkcontext.logicalDevice, commandPool, 1, &vkcontext.setupCmdBuffer);
    vkDestroyCommandPool(vkcontext.logicalDevice, commandPool, null);

    foreach(ref presentImageView; presentImageViews){
        vkDestroyImageView(vkcontext.logicalDevice, presentImageView, null);
    }

    vkDestroySwapchainKHR(vkcontext.logicalDevice, vkcontext.swapchain, null);

    vkDestroySemaphore(vkcontext.logicalDevice, vkcontext.presentCompleteSemaphore, null);
    vkDestroySemaphore(vkcontext.logicalDevice, vkcontext.renderingCompleteSemaphore, null);

    vkDestroyDevice(vkcontext.logicalDevice, null);
    vkDestroySurfaceKHR(vkcontext.instance, vkcontext.surface, null);
    vkDestroyDebugReportCallbackEXT(vkcontext.instance, callback, null);
    vkDestroyInstance(vkcontext.instance, null);
}
