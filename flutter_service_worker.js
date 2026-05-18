'use strict';
const MANIFEST = 'flutter-app-manifest';
const TEMP = 'flutter-temp-cache';
const CACHE_NAME = 'flutter-app-cache';

const RESOURCES = {"assets/shaders/ink_sparkle.frag": "ecc85a2e95f5e9f53123dcaf8cb9b6ce",
"assets/assets/config/motion/jumping.yaml": "4b8213a5e4aa5238430c19ca0ba22775",
"assets/assets/config/motion/jesse_dance.yaml": "c9639ebeb56478ac331d94ef518ff630",
"assets/assets/config/motion/zombie.yaml": "3ef2e18e87e9774db427eabf8d4c4f48",
"assets/assets/config/motion/jumping_jacks.yaml": "883ec3fda4135c5f8b01fcbb2c2e35b5",
"assets/assets/config/motion/wave_hello.yaml": "54b7f619dc85852f101061672b565691",
"assets/assets/config/motion/dab.yaml": "13d9fc2fdca96dfa34819f05ff99e6cc",
"assets/assets/config/retarget/fair1_ppf.yaml": "7846dab36820f5feaccc8e620191f899",
"assets/assets/config/retarget/mixamo_fff.yaml": "fb08c0cce9c4adc550d9303a7b0d8544",
"assets/assets/config/retarget/fair1_ppf_duo1.yaml": "5b832cd71d16cc4a7760cce06e0a3a00",
"assets/assets/config/retarget/four_legs.yaml": "c9ac17eeb1c869881986be471d5cccf3",
"assets/assets/config/retarget/cmu1_pfp.yaml": "9f70ce1e3ac6c59b9dfec451ee09de39",
"assets/assets/config/retarget/six_arms.yaml": "9003a37f58b5a0b8b3ae05ad29d34240",
"assets/assets/config/retarget/fair1_spf.yaml": "c3f3a7e622a78fd59254ae9cf811b358",
"assets/assets/config/retarget/fair1_ppf_duo2.yaml": "f81d0f9b2e87e82df7730d29689e05c8",
"assets/assets/bvh/fair1/jumping.bvh": "13df1b6e9cd700560108a6e08692333a",
"assets/assets/bvh/fair1/zombie.bvh": "6d1570432f65ff82eae3421457652a22",
"assets/assets/bvh/fair1/wave_hello.bvh": "33c3455f60274f7d8c9b212cb9a6046f",
"assets/assets/bvh/fair1/dab.bvh": "67135b71f708b8662f5f7be88a73908b",
"assets/assets/bvh/cmu1/jumping_jacks.bvh": "2114a845c3928daa8ec72f2562a231a6",
"assets/assets/bvh/rokoko/jesse_dance.bvh": "94ef6278b7493f35243ca5fb39a7ef36",
"assets/assets/models/drawn_humanoid_pose.onnx": "57d2d8aa1bd694881d98a161c52f28e2",
"assets/fonts/MaterialIcons-Regular.otf": "d479e5558e05b62e47a7283cbcf8c755",
"assets/AssetManifest.bin": "799adea7ee2b38a398f7d444eb9728bc",
"assets/FontManifest.json": "dc3d03800ccca4601324923c0b1d6d57",
"assets/AssetManifest.bin.json": "767819e637e26e277382fbd69704d897",
"assets/NOTICES": "f91831a3cd64b8dd27bfd7ccf3a49792",
"assets/packages/cupertino_icons/assets/CupertinoIcons.ttf": "33b7d9392238c04c131b6ce224e13711",
"assets/AssetManifest.json": "1902a39a8a30c21c92e2c82b5c7eab66",
"favicon.png": "5dcef449791fa27946b3d35ad8803796",
"version.json": "16ae95ab5cc2b91e8454515fce49d556",
"index.html": "66da82ccfdfb66752fe8422223a9c925",
"/": "66da82ccfdfb66752fe8422223a9c925",
"icons/Icon-maskable-192.png": "c457ef57daa1d16f64b27b786ec2ea3c",
"icons/Icon-192.png": "ac9a721a12bbc803b44f645561ecb1e1",
"icons/Icon-512.png": "96e752610906ba2a93c65f8abe1645f1",
"icons/Icon-maskable-512.png": "301a7604d45b3e739efc881eb04896ea",
"flutter.js": "888483df48293866f9f41d3d9274a779",
"canvaskit/canvaskit.wasm": "07b9f5853202304d3b0749d9306573cc",
"canvaskit/skwasm.js.symbols": "0088242d10d7e7d6d2649d1fe1bda7c1",
"canvaskit/skwasm_heavy.wasm": "8034ad26ba2485dab2fd49bdd786837b",
"canvaskit/canvaskit.js.symbols": "58832fbed59e00d2190aa295c4d70360",
"canvaskit/skwasm.js": "1ef3ea3a0fec4569e5d531da25f34095",
"canvaskit/chromium/canvaskit.wasm": "24c77e750a7fa6d474198905249ff506",
"canvaskit/chromium/canvaskit.js.symbols": "193deaca1a1424049326d4a91ad1d88d",
"canvaskit/chromium/canvaskit.js": "5e27aae346eee469027c80af0751d53d",
"canvaskit/skwasm_heavy.js": "413f5b2b2d9345f37de148e2544f584f",
"canvaskit/canvaskit.js": "140ccb7d34d0a55065fbd422b843add6",
"canvaskit/skwasm.wasm": "264db41426307cfc7fa44b95a7772109",
"canvaskit/skwasm_heavy.js.symbols": "3c01ec03b5de6d62c34e17014d1decd3",
"flutter_bootstrap.js": "5517cb7732c95214fb3ef6a256df8e4f",
"manifest.json": "8a06714a1a2a0d0e21f971e8acb411d6",
"main.dart.js": "2006f262dde98507a9012a37ec599e2c"};
// The application shell files that are downloaded before a service worker can
// start.
const CORE = ["main.dart.js",
"index.html",
"flutter_bootstrap.js",
"assets/AssetManifest.bin.json",
"assets/FontManifest.json"];

// During install, the TEMP cache is populated with the application shell files.
self.addEventListener("install", (event) => {
  self.skipWaiting();
  return event.waitUntil(
    caches.open(TEMP).then((cache) => {
      return cache.addAll(
        CORE.map((value) => new Request(value, {'cache': 'reload'})));
    })
  );
});
// During activate, the cache is populated with the temp files downloaded in
// install. If this service worker is upgrading from one with a saved
// MANIFEST, then use this to retain unchanged resource files.
self.addEventListener("activate", function(event) {
  return event.waitUntil(async function() {
    try {
      var contentCache = await caches.open(CACHE_NAME);
      var tempCache = await caches.open(TEMP);
      var manifestCache = await caches.open(MANIFEST);
      var manifest = await manifestCache.match('manifest');
      // When there is no prior manifest, clear the entire cache.
      if (!manifest) {
        await caches.delete(CACHE_NAME);
        contentCache = await caches.open(CACHE_NAME);
        for (var request of await tempCache.keys()) {
          var response = await tempCache.match(request);
          await contentCache.put(request, response);
        }
        await caches.delete(TEMP);
        // Save the manifest to make future upgrades efficient.
        await manifestCache.put('manifest', new Response(JSON.stringify(RESOURCES)));
        // Claim client to enable caching on first launch
        self.clients.claim();
        return;
      }
      var oldManifest = await manifest.json();
      var origin = self.location.origin;
      for (var request of await contentCache.keys()) {
        var key = request.url.substring(origin.length + 1);
        if (key == "") {
          key = "/";
        }
        // If a resource from the old manifest is not in the new cache, or if
        // the MD5 sum has changed, delete it. Otherwise the resource is left
        // in the cache and can be reused by the new service worker.
        if (!RESOURCES[key] || RESOURCES[key] != oldManifest[key]) {
          await contentCache.delete(request);
        }
      }
      // Populate the cache with the app shell TEMP files, potentially overwriting
      // cache files preserved above.
      for (var request of await tempCache.keys()) {
        var response = await tempCache.match(request);
        await contentCache.put(request, response);
      }
      await caches.delete(TEMP);
      // Save the manifest to make future upgrades efficient.
      await manifestCache.put('manifest', new Response(JSON.stringify(RESOURCES)));
      // Claim client to enable caching on first launch
      self.clients.claim();
      return;
    } catch (err) {
      // On an unhandled exception the state of the cache cannot be guaranteed.
      console.error('Failed to upgrade service worker: ' + err);
      await caches.delete(CACHE_NAME);
      await caches.delete(TEMP);
      await caches.delete(MANIFEST);
    }
  }());
});
// The fetch handler redirects requests for RESOURCE files to the service
// worker cache.
self.addEventListener("fetch", (event) => {
  if (event.request.method !== 'GET') {
    return;
  }
  var origin = self.location.origin;
  var key = event.request.url.substring(origin.length + 1);
  // Redirect URLs to the index.html
  if (key.indexOf('?v=') != -1) {
    key = key.split('?v=')[0];
  }
  if (event.request.url == origin || event.request.url.startsWith(origin + '/#') || key == '') {
    key = '/';
  }
  // If the URL is not the RESOURCE list then return to signal that the
  // browser should take over.
  if (!RESOURCES[key]) {
    return;
  }
  // If the URL is the index.html, perform an online-first request.
  if (key == '/') {
    return onlineFirst(event);
  }
  event.respondWith(caches.open(CACHE_NAME)
    .then((cache) =>  {
      return cache.match(event.request).then((response) => {
        // Either respond with the cached resource, or perform a fetch and
        // lazily populate the cache only if the resource was successfully fetched.
        return response || fetch(event.request).then((response) => {
          if (response && Boolean(response.ok)) {
            cache.put(event.request, response.clone());
          }
          return response;
        });
      })
    })
  );
});
self.addEventListener('message', (event) => {
  // SkipWaiting can be used to immediately activate a waiting service worker.
  // This will also require a page refresh triggered by the main worker.
  if (event.data === 'skipWaiting') {
    self.skipWaiting();
    return;
  }
  if (event.data === 'downloadOffline') {
    downloadOffline();
    return;
  }
});
// Download offline will check the RESOURCES for all files not in the cache
// and populate them.
async function downloadOffline() {
  var resources = [];
  var contentCache = await caches.open(CACHE_NAME);
  var currentContent = {};
  for (var request of await contentCache.keys()) {
    var key = request.url.substring(origin.length + 1);
    if (key == "") {
      key = "/";
    }
    currentContent[key] = true;
  }
  for (var resourceKey of Object.keys(RESOURCES)) {
    if (!currentContent[resourceKey]) {
      resources.push(resourceKey);
    }
  }
  return contentCache.addAll(resources);
}
// Attempt to download the resource online before falling back to
// the offline cache.
function onlineFirst(event) {
  return event.respondWith(
    fetch(event.request).then((response) => {
      return caches.open(CACHE_NAME).then((cache) => {
        cache.put(event.request, response.clone());
        return response;
      });
    }).catch((error) => {
      return caches.open(CACHE_NAME).then((cache) => {
        return cache.match(event.request).then((response) => {
          if (response != null) {
            return response;
          }
          throw error;
        });
      });
    })
  );
}
