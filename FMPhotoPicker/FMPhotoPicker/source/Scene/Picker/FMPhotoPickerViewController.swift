//
//  FMPhotoPickerViewController.swift
//  FMPhotoPicker
//
//  Created by c-nguyen on 2018/01/23.
//  Copyright © 2018 Tribal Media House. All rights reserved.
//

import UIKit
import Photos

// MARK: - Delegate protocol
public protocol FMPhotoPickerViewControllerDelegate: class {
    func fmPhotoPickerController(_ picker: FMPhotoPickerViewController, didFinishPickingPhotoWith photos: [UIImage])
}

public class FMPhotoPickerViewController: UIViewController {
    // MARK: - Outlet
    @IBOutlet weak var imageCollectionView: UICollectionView!
    @IBOutlet weak var numberOfSelectedPhotoContainer: UIView!
    @IBOutlet weak var numberOfSelectedPhoto: UILabel!
    @IBOutlet weak var doneButton: UIButton!
    @IBOutlet weak var controlBarTopConstrant: NSLayoutConstraint!
    
    // MARK: - Public
    public weak var delegate: FMPhotoPickerViewControllerDelegate? = nil
    
    // MARK: - Private
    
    // Index of photo that is currently displayed in PhotoPresenterViewController.
    // Track this to calculate the destination frame for dismissal animation
    // from PhotoPresenterViewController to this ViewController
    private var presentedPhotoIndex: Int?

    private let config: FMPhotoPickerConfig
    
    // The controller for multiple select/deselect
    private lazy var batchSelector: FMPhotoPickerBatchSelector = {
        return FMPhotoPickerBatchSelector(viewController: self, collectionView: self.imageCollectionView, dataSource: self.dataSource)
    }()
    
    private var dataSource: FMPhotosDataSource! {
        didSet {
            if self.config.selectMode == .multiple {
                // Enable batchSelector in multiple selection mode only
                self.batchSelector.enable()
            }
        }
    }
    
    // MARK: - Init
    public init(config: FMPhotoPickerConfig) {
        self.config = config
        super.init(nibName: "FMPhotoPickerViewController", bundle: Bundle(for: type(of: self)))
    }
    
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    
    // MARK: - Life cycle
    override public func viewDidLoad() {
        super.viewDidLoad()
        self.setupView()
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if self.dataSource == nil {
            self.requestAndFetchAssets()
        }
    }
    
    // MARK: - Setup View
    private func setupView() {
        let reuseCellNib = UINib(nibName: "FMPhotoPickerImageCollectionViewCell", bundle: Bundle(for: self.classForCoder))
        self.imageCollectionView.register(reuseCellNib, forCellWithReuseIdentifier: "FMPhotoPickerImageCollectionViewCell")
        self.imageCollectionView.dataSource = self
        self.imageCollectionView.delegate = self
        
        self.numberOfSelectedPhotoContainer.layer.cornerRadius = self.numberOfSelectedPhotoContainer.frame.size.width / 2
        self.numberOfSelectedPhotoContainer.isHidden = true
        self.doneButton.isHidden = true
        
        if #available(iOS 11.0, *) {
            guard let window = UIApplication.shared.keyWindow else { return }
            if window.safeAreaInsets.top > 0 {
                // iPhone X
                self.controlBarTopConstrant.constant = 44
            }
        }
    }
    
    // MARK: - Target Actions
    @IBAction func onTapDismiss(_ sender: Any) {
        self.dismiss(animated: true)
    }
    
    @IBAction func onTapNextStep(_ sender: Any) {
        FMLoadingView.shared.show()
        
        var dict = [Int:UIImage]()

        DispatchQueue.global(qos: .userInitiated).async {
            let multiTask = DispatchGroup()
            for (index, element) in self.dataSource.getSelectedPhotos().enumerated() {
                multiTask.enter()
                element.requestFullSizePhoto() {
                    guard let image = $0 else { return }
                    dict[index] = image
                    multiTask.leave()
                }
            }
            multiTask.wait()
            
            let result = dict.sorted(by: { $0.key < $1.key }).map { $0.value }
            DispatchQueue.main.async {
                FMLoadingView.shared.hide()
                self.delegate?.fmPhotoPickerController(self, didFinishPickingPhotoWith: result)
            }
        }
    }
    
    // MARK: - Logic
    private func requestAndFetchAssets() {
        if Helper.canAccessPhotoLib() {
            self.fetchPhotos()
        } else {
            Helper.showDialog(in: self, ok: {
                Helper.requestAuthorizationForPhotoAccess(authorized: self.fetchPhotos, rejected: Helper.openIphoneSetting)
            })
        }
    }
    
    private func fetchPhotos() {
        let photoAssets = Helper.getAssets(allowMediaTypes: self.config.mediaTypes)
        let fmPhotoAssets = photoAssets.map { FMPhotoAsset(asset: $0) }
        self.dataSource = FMPhotosDataSource(photoAssets: fmPhotoAssets)
        
        self.imageCollectionView.reloadData()
        self.imageCollectionView.selectItem(at: IndexPath(row: self.dataSource.numberOfPhotos - 1, section: 0),
                                            animated: false,
                                            scrollPosition: .bottom)
    }
    
    public func updateControlBar() {
        if self.dataSource.numberOfSelectedPhoto() > 0 {
            self.doneButton.isHidden = false
            if self.config.selectMode == .multiple {
                self.numberOfSelectedPhotoContainer.isHidden = false
                self.numberOfSelectedPhoto.text = "\(self.dataSource.numberOfSelectedPhoto())"
            }
        } else {
            self.doneButton.isHidden = true
            self.numberOfSelectedPhotoContainer.isHidden = true
        }
    }
}

// MARK: - UICollectionViewDataSource
extension FMPhotoPickerViewController: UICollectionViewDataSource {
    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if let total = self.dataSource?.numberOfPhotos {
            return total
        }
        return 0
    }
    
    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FMPhotoPickerImageCollectionViewCell.reuseId, for: indexPath) as? FMPhotoPickerImageCollectionViewCell,
            let photoAsset = self.dataSource.photo(atIndex: indexPath.item) else {
            return UICollectionViewCell()
        }
        
        cell.loadView(photoAsset: photoAsset,
                      selectMode: self.config.selectMode,
                      selectedIndex: self.dataSource.selectedIndexOfPhoto(atIndex: indexPath.item))
        cell.onTapSelect = {
            if let selectedIndex = self.dataSource.selectedIndexOfPhoto(atIndex: indexPath.item) {
                self.dataSource.unsetSeclectedForPhoto(atIndex: indexPath.item)
                cell.performSelectionAnimation(selectedIndex: nil)
                self.reloadAffectedCellByChangingSelection(changedIndex: selectedIndex)
            } else {
                self.tryToAddPhotoToSelectedList(photoIndex: indexPath.item)
            }
            self.updateControlBar()
        }
        
        return cell
    }
    
    /**
     Reload all photocells that behind the deselected photocell
     - parameters:
        - changedIndex: The index of the deselected photocell in the selected list
     */
    public func reloadAffectedCellByChangingSelection(changedIndex: Int) {
        let affectedList = self.dataSource.affectedSelectedIndexs(changedIndex: changedIndex)
        let indexPaths = affectedList.map { return IndexPath(row: $0, section: 0) }
        self.imageCollectionView.reloadItems(at: indexPaths)
    }
    
    /**
     Try to insert the photo at specify index to selectd list.
     In Single selection mode, it will remove all the previous selection and add new photo to the selected list.
     In Multiple selection mode, If the current number of select image/video does not exceed the maximum number specified in the Config,
     the photo will be added to selected list. Otherwise, a warning dialog will be displayed and NOTHING will be added.
     */
    public func tryToAddPhotoToSelectedList(photoIndex index: Int) {
        if self.config.selectMode == .multiple {
            guard let phMediaType = self.dataSource.mediaTypeForPhoto(atIndex: index),
                let fmMediaType = FMMediaType(withPHAssetMediaType: phMediaType) else { return }
            var canBeAdded = true
            switch fmMediaType {
            case .image:
                if self.dataSource.countSelectedPhoto(byType: .image) >= self.config.maxImage {
                    canBeAdded = false
                    let warning = FMWarningView.shared
                    warning.message = "画像は最大\(self.config.maxImage)個まで選択できます。"
                    warning.showAndAutoHide()
                }
            case .video:
                if self.dataSource.countSelectedPhoto(byType: .video) >= self.config.maxVideo {
                    canBeAdded = false
                    let warning = FMWarningView.shared
                    warning.message = "動画は最大\(self.config.maxVideo)個まで選択できます。"
                    warning.showAndAutoHide()
                }
            }
            
            if canBeAdded {
                self.dataSource.setSeletedForPhoto(atIndex: index)
                self.imageCollectionView.reloadItems(at: [IndexPath(row: index, section: 0)])
                self.updateControlBar()
            }
        } else {  // single selection mode
            var indexPaths = [IndexPath]()
            self.dataSource.getSelectedPhotos().forEach { photo in
                guard let photoIndex = self.dataSource.index(ofPhoto: photo) else { return }
                indexPaths.append(IndexPath(row: photoIndex, section: 0))
                self.dataSource.unsetSeclectedForPhoto(atIndex: photoIndex)
            }
            
            self.dataSource.setSeletedForPhoto(atIndex: index)
            indexPaths.append(IndexPath(row: index, section: 0))
            self.imageCollectionView.reloadItems(at: indexPaths)
            self.updateControlBar()
        }
    }
}

// MARK: - UICollectionViewDelegate
extension FMPhotoPickerViewController: UICollectionViewDelegate {
    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let vc = FMPhotoPresenterViewController(selectMode: self.config.selectMode, dataSource: self.dataSource, initialPhotoIndex: indexPath.item)
        
        self.presentedPhotoIndex = indexPath.item
        
        vc.didSelectPhotoHandler = { photoIndex in
            self.tryToAddPhotoToSelectedList(photoIndex: photoIndex)
        }
        vc.didDeselectPhotoHandler = { photoIndex in
            if let selectedIndex = self.dataSource.selectedIndexOfPhoto(atIndex: photoIndex) {
                self.dataSource.unsetSeclectedForPhoto(atIndex: photoIndex)
                self.reloadAffectedCellByChangingSelection(changedIndex: selectedIndex)
                self.imageCollectionView.reloadItems(at: [IndexPath(row: photoIndex, section: 0)])
                self.updateControlBar()
            }
        }
        vc.didMoveToViewControllerHandler = { vc, photoIndex in
            self.presentedPhotoIndex = photoIndex
        }
        
        vc.view.frame = self.view.frame
        vc.transitioningDelegate = self
        vc.modalPresentationStyle = .custom
        vc.modalPresentationCapturesStatusBarAppearance = true
        self.present(vc, animated: true)
    }
}

// MARK: - UIViewControllerTransitioningDelegate
extension FMPhotoPickerViewController: UIViewControllerTransitioningDelegate {
    public func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        let animationController = FMZoomInAnimationController()
        animationController.getOriginFrame = self.getOriginFrameForTransition
        return animationController
    }
    
    public func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard let photoPresenterViewController = dismissed as? FMPhotoPresenterViewController else { return nil }
        let animationController = FMZoomOutAnimationController(interactionController: photoPresenterViewController.swipeInteractionController)
        animationController.getDestFrame = self.getOriginFrameForTransition
        return animationController
    }
    
    open func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        guard let animator = animator as? FMZoomOutAnimationController,
            let interactionController = animator.interactionController,
            interactionController.interactionInProgress
            else {
                return nil
        }
        
        interactionController.animator = animator
        return interactionController
    }
    
    func getOriginFrameForTransition() -> CGRect {
        guard let presentedPhotoIndex = self.presentedPhotoIndex,
            let cell = self.imageCollectionView.cellForItem(at: IndexPath(row: presentedPhotoIndex, section: 0))
            else {
                return CGRect(x: 0, y: self.view.frame.height, width: self.view.frame.size.width, height: self.view.frame.size.width)
        }
        return cell.convert(cell.bounds, to: self.view)
    }
}
