// OutputSurfaceMetalView — renders IOSurface thumbnails at full display refresh rate.
// NSViewRepresentable wrapping MTKView. Inline Metal shaders, aspect-fill scaling,
// texture caching per IOSurface identity. Renders at CAMetalDisplayLink rate (60fps).

import IOSurface
import MetalKit
import SwiftUI
import simd

struct OutputSurfaceMetalView: NSViewRepresentable {
    let renderFeed: OutputTileRenderFeed

    func makeCoordinator() -> Coordinator {
        Coordinator(renderFeed: renderFeed)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1.0)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = false
        view.delegate = context.coordinator
        context.coordinator.attach(to: view, renderFeed: renderFeed)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.attach(to: nsView, renderFeed: renderFeed)
    }

    // MARK: - Coordinator (MTKViewDelegate)

    final class Coordinator: NSObject, MTKViewDelegate {
        private struct Vertex {
            var position: SIMD2<Float>
            var texCoord: SIMD2<Float>
        }

        fileprivate let device = MTLCreateSystemDefaultDevice()
        private lazy var commandQueue = device?.makeCommandQueue()
        private lazy var samplerState = makeSamplerState()
        private lazy var pipelineState = makePipelineState()
        private var renderFeed: OutputTileRenderFeed
        private weak var view: MTKView?

        private var cachedSurfaceObjectID: ObjectIdentifier?
        private var cachedTexture: MTLTexture?
        private var lastPresentedSurfaceObjectID: ObjectIdentifier?
        private var lastPresentedSequence: UInt64 = 0
        private var lastDrawableSize: CGSize = .zero
        private var needsClear = true

        init(renderFeed: OutputTileRenderFeed) {
            self.renderFeed = renderFeed
        }

        func attach(to view: MTKView, renderFeed: OutputTileRenderFeed) {
            self.view = view
            self.renderFeed = renderFeed
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            if size != lastDrawableSize {
                needsClear = true
            }
        }

        func draw(in view: MTKView) {
            let feedSnapshot = renderFeed.snapshot()
            let drawableSize = view.drawableSize

            // No surface — clear once then skip until surface arrives or size changes
            if feedSnapshot.surface == nil {
                guard needsClear
                        || lastPresentedSurfaceObjectID != nil
                        || drawableSize != lastDrawableSize else {
                    return
                }
                render(surface: nil, sequence: 0, in: view)
                lastPresentedSurfaceObjectID = nil
                lastPresentedSequence = 0
                lastDrawableSize = drawableSize
                needsClear = false
                return
            }

            // Skip redraw if nothing changed
            let surfaceObjectID = feedSnapshot.surface.map(ObjectIdentifier.init)
            guard needsClear
                    || surfaceObjectID != lastPresentedSurfaceObjectID
                    || feedSnapshot.sequence != lastPresentedSequence
                    || drawableSize != lastDrawableSize else {
                return
            }

            render(surface: feedSnapshot.surface, sequence: feedSnapshot.sequence, in: view)
            lastPresentedSurfaceObjectID = surfaceObjectID
            lastPresentedSequence = feedSnapshot.sequence
            lastDrawableSize = drawableSize
            needsClear = false
        }

        // MARK: - Rendering

        private func render(surface: IOSurface?, sequence: UInt64, in view: MTKView) {
            guard let commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable
            else {
                return
            }

            if let pipelineState,
               let samplerState,
               let texture = texture(for: surface) {
                let vertices = aspectFillVertices(
                    sourceWidth: texture.width,
                    sourceHeight: texture.height,
                    destinationWidth: Int(view.drawableSize.width),
                    destinationHeight: Int(view.drawableSize.height)
                )
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                    return
                }
                encoder.setRenderPipelineState(pipelineState)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(samplerState, index: 0)
                encoder.setVertexBytes(vertices, length: MemoryLayout<Vertex>.stride * vertices.count, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
                encoder.endEncoding()
            }

            commandBuffer.label = "OutputTileRender(seq=\(sequence))"
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        // MARK: - Texture Cache

        private func texture(for surface: IOSurface?) -> MTLTexture? {
            guard let device else { return nil }
            guard let surface else {
                cachedSurfaceObjectID = nil
                cachedTexture = nil
                return nil
            }

            let surfaceObjectID = ObjectIdentifier(surface)
            if cachedSurfaceObjectID == surfaceObjectID,
               let cachedTexture {
                return cachedTexture
            }

            let width = IOSurfaceGetWidth(surface)
            let height = IOSurfaceGetHeight(surface)
            guard width > 0, height > 0 else { return nil }

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
            cachedSurfaceObjectID = surfaceObjectID
            cachedTexture = texture
            return texture
        }

        // MARK: - Sampler & Pipeline

        private func makeSamplerState() -> MTLSamplerState? {
            guard let device else { return nil }
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = .linear
            descriptor.magFilter = .linear
            descriptor.sAddressMode = .clampToEdge
            descriptor.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: descriptor)
        }

        private func makePipelineState() -> MTLRenderPipelineState? {
            guard let device else { return nil }
            let source = """
            #include <metal_stdlib>
            using namespace metal;

            struct VertexIn {
                float2 position;
                float2 texCoord;
            };

            struct RasterizerData {
                float4 position [[position]];
                float2 texCoord;
            };

            vertex RasterizerData output_tile_vertex(
                const device VertexIn *vertices [[buffer(0)]],
                uint vertexID [[vertex_id]]
            ) {
                RasterizerData out;
                out.position = float4(vertices[vertexID].position, 0.0, 1.0);
                out.texCoord = vertices[vertexID].texCoord;
                return out;
            }

            fragment float4 output_tile_fragment(
                RasterizerData in [[stage_in]],
                texture2d<float> textureIn [[texture(0)]],
                sampler samplerIn [[sampler(0)]]
            ) {
                return textureIn.sample(samplerIn, in.texCoord);
            }
            """

            do {
                let library = try device.makeLibrary(source: source, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "output_tile_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "output_tile_fragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                NSLog("OutputSurfaceMetalView: failed to compile Metal pipeline: %@", error.localizedDescription)
                return nil
            }
        }

        // MARK: - Aspect Fill

        private func aspectFillVertices(
            sourceWidth: Int,
            sourceHeight: Int,
            destinationWidth: Int,
            destinationHeight: Int
        ) -> [Vertex] {
            guard sourceWidth > 0,
                  sourceHeight > 0,
                  destinationWidth > 0,
                  destinationHeight > 0
            else {
                return fullscreenVertices(uMin: 0, uMax: 1, vMin: 0, vMax: 1)
            }

            let sourceAspect = Float(sourceWidth) / Float(sourceHeight)
            let destinationAspect = Float(destinationWidth) / Float(destinationHeight)

            var uMin: Float = 0
            var uMax: Float = 1
            var vMin: Float = 0
            var vMax: Float = 1

            if sourceAspect > destinationAspect {
                let visibleWidth = destinationAspect / sourceAspect
                let inset = (1 - visibleWidth) * 0.5
                uMin = inset
                uMax = 1 - inset
            } else if sourceAspect < destinationAspect {
                let visibleHeight = sourceAspect / destinationAspect
                let inset = (1 - visibleHeight) * 0.5
                vMin = inset
                vMax = 1 - inset
            }

            return fullscreenVertices(uMin: uMin, uMax: uMax, vMin: vMin, vMax: vMax)
        }

        private func fullscreenVertices(
            uMin: Float,
            uMax: Float,
            vMin: Float,
            vMax: Float
        ) -> [Vertex] {
            [
                Vertex(position: SIMD2(-1, -1), texCoord: SIMD2(uMin, vMax)),
                Vertex(position: SIMD2(1, -1), texCoord: SIMD2(uMax, vMax)),
                Vertex(position: SIMD2(-1, 1), texCoord: SIMD2(uMin, vMin)),
                Vertex(position: SIMD2(-1, 1), texCoord: SIMD2(uMin, vMin)),
                Vertex(position: SIMD2(1, -1), texCoord: SIMD2(uMax, vMax)),
                Vertex(position: SIMD2(1, 1), texCoord: SIMD2(uMax, vMin)),
            ]
        }
    }
}
