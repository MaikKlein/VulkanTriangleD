# Simple example for a triangle in Vulkan

##Dependencies

* SDL2
* Vulkan driver + compatible hardware
* Vulkan SDK from LunarG with validation layers
* Vulkan lib
* Currently only supported on Linux

## How to build and run

```
git clone https://github.com/MaikKlein/VulkanTriangleD.git
cd VulkanTriangleD
git submodule init
git submodule update
dub run
```

![Triangle](https://i.imgur.com/b1JRKdW.png)

## A thanks to

* [Api with no secrets](https://software.intel.com/en-us/articles/api-without-secrets-introduction-to-vulkan-part-1)
* [Vulkan tutorial](http://av.dfki.de/~jhenriques/development.html)
* [Vulkan examples](https://github.com/SaschaWillems/Vulkan)
