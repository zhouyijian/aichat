import UIKit

final class ConversationListViewController: UIViewController {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .current
        formatter.unitsStyle = .short
        return formatter
    }()

    private var summaries: [ConversationSummary]
    private let onSelectConversation: (UUID) -> Void
    private let onCreateConversation: () -> Void

    init(
        summaries: [ConversationSummary],
        onSelectConversation: @escaping (UUID) -> Void,
        onCreateConversation: @escaping () -> Void
    ) {
        self.summaries = summaries
        self.onSelectConversation = onSelectConversation
        self.onCreateConversation = onCreateConversation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "会话列表"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(didTapClose)
        )

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(didTapCreate)
        )

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ConversationCell")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 74

        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc
    private func didTapClose() {
        dismiss(animated: true)
    }

    @objc
    private func didTapCreate() {
        onCreateConversation()
        dismiss(animated: true)
    }

    private func relativeTimeString(for date: Date) -> String {
        dateFormatter.localizedString(for: date, relativeTo: Date())
    }
}

extension ConversationListViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        summaries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ConversationCell", for: indexPath)
        let item = summaries[indexPath.row]

        var content = UIListContentConfiguration.subtitleCell()
        content.text = item.title
        content.secondaryText = "\(item.preview) · \(relativeTimeString(for: item.updatedAt))"
        content.textProperties.numberOfLines = 1
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content

        cell.accessoryType = item.isSelected ? .checkmark : .none
        cell.selectionStyle = .default
        return cell
    }
}

extension ConversationListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = summaries[indexPath.row]
        onSelectConversation(item.id)
        dismiss(animated: true)
    }
}
