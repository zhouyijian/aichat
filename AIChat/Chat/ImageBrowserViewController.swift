import UIKit
import SnapKit

final class ImageBrowserViewController: UIViewController, UIScrollViewDelegate {

    private let imageURL: URL
    private let initialImage: UIImage?
    private let caption: String?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let captionLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let placeholderLabel = UILabel()
    private var task: URLSessionDataTask?
    private var didSetInitialZoom = false

    init(imageURL: URL, image: UIImage?, caption: String?) {
        self.imageURL = imageURL
        self.initialImage = image
        self.caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        task?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()

        if let initialImage {
            display(image: initialImage)
        } else {
            loadImage()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        captionLabel.preferredMaxLayoutWidth = view.bounds.width - 40
        updateZoomScalesIfNeeded()
        centerImageIfNeeded()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageIfNeeded()
    }

    private func setupViews() {
        view.backgroundColor = .black

        scrollView.backgroundColor = .black
        scrollView.delegate = self
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.contentInsetAdjustmentBehavior = .never

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true

        placeholderLabel.text = "图片加载中"
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.font = .systemFont(ofSize: 15)
        placeholderLabel.textAlignment = .center

        captionLabel.text = caption
        captionLabel.isHidden = caption?.isEmpty ?? true
        captionLabel.numberOfLines = 0
        captionLabel.font = .systemFont(ofSize: 14)
        captionLabel.textColor = .white
        captionLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        captionLabel.layer.cornerRadius = 8
        captionLabel.layer.masksToBounds = true

        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        closeButton.layer.cornerRadius = 22
        closeButton.accessibilityLabel = "关闭图片浏览"
        closeButton.addTarget(self, action: #selector(dismissBrowser), for: .touchUpInside)

        view.addSubview(scrollView)
        scrollView.addSubview(imageView)
        view.addSubview(placeholderLabel)
        view.addSubview(captionLabel)
        view.addSubview(closeButton)

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        placeholderLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(24)
        }
        captionLabel.snp.makeConstraints { make in
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20)
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(16)
        }
        closeButton.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(12)
            make.trailing.equalTo(view.safeAreaLayoutGuide).inset(16)
            make.width.height.equalTo(44)
        }

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(dismissBrowser))
        swipeDown.direction = .down
        view.addGestureRecognizer(swipeDown)
    }

    private func loadImage() {
        let resolvedURL = GeneratedImageStore.resolvedURL(for: imageURL) ?? imageURL
        if resolvedURL.isFileURL {
            loadLocalImage(resolvedURL)
            return
        }

        task?.cancel()
        task = URLSession.shared.dataTask(with: resolvedURL) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data, let image = UIImage(data: data) else {
                DispatchQueue.main.async { [weak self] in
                    self?.placeholderLabel.text = "图片加载失败"
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.display(image: image)
            }
        }
        task?.resume()
    }

    private func loadLocalImage(_ fileURL: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let data = try? Data(contentsOf: fileURL),
                  let image = UIImage(data: data) else {
                DispatchQueue.main.async { [weak self] in
                    self?.placeholderLabel.text = "图片加载失败"
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.display(image: image)
            }
        }
    }

    private func display(image: UIImage) {
        placeholderLabel.isHidden = true
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        scrollView.contentSize = image.size
        didSetInitialZoom = false
        updateZoomScalesIfNeeded()
        centerImageIfNeeded()
    }

    private func updateZoomScalesIfNeeded() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }

        let boundsSize = scrollView.bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return }

        let widthScale = boundsSize.width / image.size.width
        let heightScale = boundsSize.height / image.size.height
        let minScale = min(widthScale, heightScale)
        let fitScale = min(max(minScale, 0.01), 1)
        scrollView.minimumZoomScale = fitScale
        scrollView.maximumZoomScale = max(fitScale * 4, 3)

        if !didSetInitialZoom {
            scrollView.zoomScale = fitScale
            didSetInitialZoom = true
        } else if scrollView.zoomScale < fitScale {
            scrollView.zoomScale = fitScale
        }

        scrollView.contentSize = CGSize(
            width: image.size.width * scrollView.zoomScale,
            height: image.size.height * scrollView.zoomScale
        )
    }

    private func centerImageIfNeeded() {
        let boundsSize = scrollView.bounds.size
        let contentSize = scrollView.contentSize
        let horizontalInset = max(0, (boundsSize.width - contentSize.width) / 2)
        let verticalInset = max(0, (boundsSize.height - contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: verticalInset, left: horizontalInset, bottom: verticalInset, right: horizontalInset)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard imageView.image != nil else { return }

        if scrollView.zoomScale > scrollView.minimumZoomScale * 1.2 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }

        let point = recognizer.location(in: imageView)
        let targetScale = min(scrollView.maximumZoomScale, scrollView.minimumZoomScale * 2.5)
        let zoomSize = CGSize(
            width: scrollView.bounds.width / targetScale,
            height: scrollView.bounds.height / targetScale
        )
        let zoomRect = CGRect(
            x: point.x - zoomSize.width / 2,
            y: point.y - zoomSize.height / 2,
            width: zoomSize.width,
            height: zoomSize.height
        )
        scrollView.zoom(to: zoomRect, animated: true)
    }

    @objc private func handleSingleTap() {
        let shouldHide = !closeButton.isHidden
        UIView.animate(withDuration: 0.2) {
            self.closeButton.alpha = shouldHide ? 0 : 1
            self.captionLabel.alpha = shouldHide ? 0 : 1
        } completion: { _ in
            self.closeButton.isHidden = shouldHide
            self.captionLabel.isHidden = shouldHide || (self.caption?.isEmpty ?? true)
        }
    }

    @objc private func dismissBrowser() {
        dismiss(animated: true)
    }
}
