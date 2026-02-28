//
//  ViewController.swift
//  AIChat
//
//  Created by 周一见 on 2026/2/28.
//

import UIKit
import SnapKit


 class ChatViewController: UIViewController {


    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Message>!
    private var messages: [Message] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Chat"

        setupCollectionView()
        setupDataSource()
        loadMockData()
        applySnapshot()
    }

    private func setupCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 10
        layout.minimumInteritemSpacing = 0
        

        // 整体 padding（上下左右留白）
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        layout.estimatedItemSize = .zero

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self

        collectionView.register(MessageCell.self, forCellWithReuseIdentifier: MessageCell.reuseID)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        collectionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func setupDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, Message>(
            collectionView: collectionView
        ) { collectionView, indexPath, message in

            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: MessageCell.reuseID,
                for: indexPath
            ) as? MessageCell else {
                return UICollectionViewCell()
            }

            cell.configure(with: message)
            return cell
        }
    }

    private func loadMockData() {
        messages = [
            Message(role: .user, content: "Hello"),
            Message(role: .assistant, content: "Hi! This is a static chat cell."),
            Message(role: .user, content: "Hello2"),
            Message(role: .user, content: "Hello3"),
            Message(role: .assistant, content: "Hi! This is a static chat cell2.Hi! This is a static chat cell2.Hi! This is a static chat cell2.Hi! This is a static chat cell2.Hi! This is a static chat cell2.Hi! This is a static chat cell2.")
        ]
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Message>()
        snapshot.appendSections([.main])
        snapshot.appendItems(messages, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: true)
    }
}

extension ChatViewController: UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {

        let layout = collectionViewLayout as! UICollectionViewFlowLayout
        let insets = layout.sectionInset
        let width = collectionView.bounds.width - insets.left - insets.right

        // 用一个“离屏 cell”算高度（缓存会更好，这里先给你最直观的）
        let cell = MessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 1000))
        cell.layoutIfNeeded()

        cell.configure(with:  messages[indexPath.item])

        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let size = cell.contentView.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: width, height: size.height)
    }
}

#Preview("Mock Chat") {
    UINavigationController(rootViewController: ChatViewController())
}

