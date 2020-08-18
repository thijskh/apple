//
//  ConnectionViewController.swift
//  EduVPN
//
//  Created by Johan Kool on 28/05/2020.
//

import Foundation
import AppKit
import PromiseKit
import os.log

protocol ConnectionViewControllerDelegate: class {
    func connectionViewControllerAttemptingToConnect(connectionAttempt: ConnectionAttempt?)
}

enum ConnectionViewControllerError: Error {
    case noProfiles
    case noSelectedProfile
    case noProfileFoundWithSelectedProfileId
}

extension ConnectionViewControllerError: AppError {
    var summary: String {
        switch self {
        case .noProfiles: return "No profiles found"
        case .noSelectedProfile: return "No profile selected"
        case .noProfileFoundWithSelectedProfileId: return "Selected profile doesn't exist"
        }
    }
}

final class ConnectionViewController: ViewController, ParametrizedViewController {

    struct Parameters {
        let environment: Environment
        let server: ServerInstance
        let serverDisplayInfo: ServerDisplayInfo
        let restoredPreConnectionState: ConnectionAttempt.PreConnectionState?
    }

    weak var delegate: ConnectionViewControllerDelegate?

    private var parameters: Parameters!
    private var isRestored: Bool = false
    private var viewModel: ConnectionViewModel!
    private var dataStore: PersistenceService.DataStore!

    private var profiles: [ProfileListResponse.Profile]?
    private var selectedProfileId: String? {
        didSet {
            dataStore.selectedProfileId = selectedProfileId ?? ""
        }
    }

    @IBOutlet weak var serverNameLabel: NSTextField!
    @IBOutlet weak var serverCountryFlagImageView: NSImageView!

    @IBOutlet weak var supportContactStackView: NSStackView!
    @IBOutlet weak var supportContactLabel: NSTextField!

    @IBOutlet weak var connectionStatusImageView: NSImageView!
    @IBOutlet weak var statusLabel: NSTextField!
    @IBOutlet weak var statusDetailLabel: NSTextField!

    @IBOutlet weak var vpnSwitchButton: NSButton!

    @IBOutlet weak var bottomStackView: NSStackView!

    @IBOutlet weak var additionalControlContainer: NSView!
    @IBOutlet weak var profileSelectorStackView: NSStackView!
    @IBOutlet weak var profileSelectorPopupButton: NSPopUpButton!
    @IBOutlet weak var renewSessionButton: NSButton!
    @IBOutlet weak var spinner: NSProgressIndicator!

    @IBOutlet weak var connectionInfoHeader: NSView!
    @IBOutlet weak var connectionInfoChevronButton: NSButton!

    @IBOutlet weak var connectionInfoBody: NSView!
    @IBOutlet weak var durationLabel: NSTextField!
    @IBOutlet weak var profileTitleLabel: NSTextField!
    @IBOutlet weak var profileNameLabel: NSTextField!
    @IBOutlet weak var dataTransferredLabel: NSTextField!
    @IBOutlet weak var addressLabel: NSTextField!

    @IBOutlet weak var serverCountryFlagImageWidthConstraint: NSLayoutConstraint!
    // swiftlint:disable:next identifier_name
    @IBOutlet weak var additionalControlContainerHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var connectionInfoBodyHeightConstraint: NSLayoutConstraint!

    func initializeParameters(_ parameters: Parameters) {
        guard self.parameters == nil else {
            fatalError("Can't initialize parameters twice")
        }
        self.parameters = parameters

        self.viewModel = ConnectionViewModel(
            serverAPIService: parameters.environment.serverAPIService,
            connectionService: parameters.environment.connectionService,
            server: parameters.server,
            serverDisplayInfo: parameters.serverDisplayInfo,
            restoredPreConnectionState: parameters.restoredPreConnectionState)
        self.dataStore = PersistenceService.DataStore(path: parameters.server.localStoragePath)

        if let restoredPreConnectionState = parameters.restoredPreConnectionState {
            self.profiles = restoredPreConnectionState.profiles
            self.selectedProfileId = restoredPreConnectionState.selectedProfileId
            self.isRestored = true
        } else {
            self.selectedProfileId = dataStore.selectedProfileId
            self.isRestored = false
        }
    }

    override func viewDidLoad() {
        // The view model delegate is set only after our views are ready
        // to receive updates from the view model
        viewModel.delegate = self
        setupInitialView(viewModel: viewModel)
        if !isRestored {
            beginConnectionFlow(shouldContinueIfSingleProfile: true)
        }
    }

    @IBAction func vpnSwitchToggled(_ sender: Any) {
        switch vpnSwitchButton.state {
        case .on:
            guard let profiles = profiles, !profiles.isEmpty else {
                beginConnectionFlow(shouldContinueIfSingleProfile: true)
                return
            }
            if selectedProfileId == nil {
                selectedProfileId = profiles[0].profileId
            }
            continueConnectionFlow(serverAPIOptions: [])

        case .off:
            disableVPN()

        default:
            break
        }
    }

    @IBAction func profileSelected(_ sender: Any) {
        let selectedIndex = profileSelectorPopupButton.indexOfSelectedItem
        if let profiles = profiles,
            selectedIndex >= 0,
            selectedIndex < profiles.count {
            selectedProfileId = profiles[selectedIndex].profileId
        }
    }

    @IBAction func renewSessionClicked(_ sender: Any) {
        continueConnectionFlow(serverAPIOptions: [.ignoreStoredAuthState, .ignoreStoredKeyPair])
    }

    @IBAction func connectionInfoChevronClicked(_ sender: Any) {
        viewModel.toggleConnectionInfoExpanded()
    }
}

private extension ConnectionViewController {
    func setupInitialView(viewModel: ConnectionViewModel) {
        canGoBackChanged(canGoBack: viewModel.canGoBack)
        headerChanged(viewModel.header)
        supportContactChanged(viewModel.supportContact)
        statusChanged(viewModel.status)
        statusDetailChanged(viewModel.statusDetail)
        vpnSwitchStateChanged(viewModel.vpnSwitchState)
        additionalControlChanged(viewModel.additionalControl)
        connectionInfoStateChanged(viewModel.connectionInfoState)
    }

    func beginConnectionFlow(shouldContinueIfSingleProfile: Bool) {
        firstly {
            viewModel.beginConnectionFlow(from: self, shouldContinueIfSingleProfile: shouldContinueIfSingleProfile)
        }.catch { error in
            os_log("Error beginning connection flow: %{public}@",
                   log: Log.general, type: .error,
                   error.localizedDescription)
            self.showAlert(for: error)
        }
    }

    func continueConnectionFlow(serverAPIOptions: ServerAPIService.Options) {
        firstly { () -> Promise<Void> in
            guard let profiles = profiles, !profiles.isEmpty else {
                return Promise(error: ConnectionViewControllerError.noProfiles)
            }
            guard let selectedProfileId = selectedProfileId else {
                return Promise(error: ConnectionViewControllerError.noSelectedProfile)
            }
            guard let profile = profiles.first(where: { $0.profileId == selectedProfileId }) else {
                return Promise(error: ConnectionViewControllerError.noProfileFoundWithSelectedProfileId)
            }
            return viewModel.continueConnectionFlow(profile: profile, from: self,
                                                    serverAPIOptions: serverAPIOptions)
        }.catch { error in
            os_log("Error continuing connection flow: %{public}@",
                   log: Log.general, type: .error,
                   error.localizedDescription)
            self.showAlert(for: error)
        }
    }

    func disableVPN() {
        firstly {
            viewModel.disableVPN()
        }.catch { error in
            os_log("Error disabling VPN: %{public}@",
                   log: Log.general, type: .error,
                   error.localizedDescription)
            self.showAlert(for: error)
        }
    }

    private func showAlert(for error: Error) {
        if let serverAPIError = error as? ServerAPIServiceError,
            case ServerAPIServiceError.errorGettingProfileConfig = serverAPIError {
            // If there's an error getting profile config, offer to refresh profiles
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = serverAPIError.summary
            alert.informativeText = serverAPIError.detail
            alert.addButton(withTitle: NSLocalizedString("Refresh Profiles", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            if let window = self.view.window {
                alert.beginSheetModal(for: window) { result in
                    if case .alertFirstButtonReturn = result {
                        self.beginConnectionFlow(shouldContinueIfSingleProfile: true)
                    }
                }
            }
            return
        }
        if !self.parameters.environment.serverAuthService.isUserCancelledError(error) {
            self.parameters.environment.navigationController?.showAlert(for: error)
        }
    }

}

extension ConnectionViewController: ConnectionViewModelDelegate {

    func profilesFound(profiles: [ProfileListResponse.Profile]) {
        self.profiles = profiles
        if let selectedProfileId = selectedProfileId {
            if !profiles.contains(where: { $0.profileId == selectedProfileId }) {
                // The current selectedProfileId is invalid
                self.selectedProfileId = nil
            }
        }
    }

    func canGoBackChanged(canGoBack: Bool) {
        parameters.environment.navigationController?.isUserAllowedToGoBack = canGoBack
    }

    func automaticallySelectingProfile(profileId: String) {
        selectedProfileId = profileId
    }

    func attemptingToConnect(
        profileId: String, certificateValidityRange: ServerAPIService.CertificateValidityRange, connectionAttemptId: UUID) {
        let connectionAttempt = ConnectionAttempt(
            server: parameters.server, profiles: profiles ?? [],
            selectedProfileId: profileId,
            certificateValidityRange: certificateValidityRange,
            attemptId: connectionAttemptId)
        delegate?.connectionViewControllerAttemptingToConnect(connectionAttempt: connectionAttempt)
    }

    static let serverCountryFlagImageWidth: CGFloat = 24

    func headerChanged(_ header: ConnectionViewModel.Header) {
        serverNameLabel.stringValue = header.serverName
        if header.flagCountryCode.isEmpty {
            serverCountryFlagImageView.image = nil
            serverCountryFlagImageWidthConstraint.constant = 0
        } else {
            serverCountryFlagImageView.image = Image(named: "CountryFlag_\(header.flagCountryCode)")
            serverCountryFlagImageWidthConstraint.constant = Self.serverCountryFlagImageWidth
        }
    }

    func supportContactChanged(_ supportContact: ConnectionViewModel.SupportContact) {
        if supportContact.supportContact.isEmpty {
            supportContactStackView.isHidden = true
            supportContactLabel.attributedStringValue = NSAttributedString()
        } else {
            supportContactStackView.isHidden = false
            supportContactLabel.attributedStringValue = supportContact.attributedStringValue
        }
    }

    func statusChanged(_ status: ConnectionViewModel.Status) {
        connectionStatusImageView.image = { () -> Image? in
            switch status {
            case .notConnected, .gettingProfiles, .configuring:
                return Image(named: "StatusNotConnected")
            case .connecting, .reconnecting, .disconnecting:
                return Image(named: "StatusConnecting")
            case .connected:
                return Image(named: "StatusConnected")
            }
        }()
        statusLabel.stringValue = status.localizedText
    }

    func statusDetailChanged(_ statusDetail: ConnectionViewModel.StatusDetail) {
        statusDetailLabel.stringValue = statusDetail.localizedText
    }

    func vpnSwitchStateChanged(_ vpnSwitchState: ConnectionViewModel.VPNSwitchState) {
        vpnSwitchButton.isEnabled = vpnSwitchState.isEnabled
        vpnSwitchButton.state = vpnSwitchState.isOn ? .on : .off
    }

    func additionalControlChanged(_ additionalControl: ConnectionViewModel.AdditionalControl) {
        switch additionalControl {
        case .none:
            profileSelectorStackView.isHidden = true
            renewSessionButton.isHidden = true
            spinner.stopAnimation(self)
        case .spinner:
            profileSelectorStackView.isHidden = true
            renewSessionButton.isHidden = true
            spinner.startAnimation(self)
        case .profileSelector(let profiles):
            profileSelectorStackView.isHidden = false
            renewSessionButton.isHidden = true
            spinner.stopAnimation(self)
            profileSelectorPopupButton.removeAllItems()
            var selectedIndex: Int?
            for (index, profile) in profiles.enumerated() {
                let profileName = profile.displayName.string(for: Locale.current)
                profileSelectorPopupButton.addItem(withTitle: profileName)
                if profile.profileId == selectedProfileId {
                    selectedIndex = index
                }
            }
            if let selectedIndex = selectedIndex {
                profileSelectorPopupButton.selectItem(at: selectedIndex)
            }
            profileSelectorPopupButton.isEnabled = true
            self.profiles = profiles
        case .renewSessionButton:
            profileSelectorStackView.isHidden = true
            renewSessionButton.isHidden = false
            spinner.stopAnimation(self)
        }
    }

    static let connectionInfoBodyHeight: CGFloat = 100
    static let additionalControlContainerHeight = connectionInfoBodyHeight

    func connectionInfoStateChanged(_ connectionInfoState: ConnectionViewModel.ConnectionInfoState) {
        connectionInfoStateChanged(connectionInfoState, animated: true)
    }

    // swiftlint:disable:next function_body_length
    func connectionInfoStateChanged(
        _ connectionInfoState: ConnectionViewModel.ConnectionInfoState, animated: Bool) {
        let controlAlpha: Float
        let controlHeight: CGFloat
        let isHeaderHidden: Bool
        let bodyAlpha: Float
        let bodyHeight: CGFloat

        switch connectionInfoState {
        case .hidden:
            controlAlpha = 1
            controlHeight = Self.additionalControlContainerHeight
            isHeaderHidden = true
            bodyAlpha = 0
            bodyHeight = 0
            connectionInfoChevronButton.image = Image(named: Image.goRightTemplateName)
        case .collapsed:
            controlAlpha = 1
            controlHeight = Self.additionalControlContainerHeight
            isHeaderHidden = false
            bodyAlpha = 0
            bodyHeight = 0
            connectionInfoChevronButton.image = Image(named: Image.goRightTemplateName)
        case .expanded(let connectionInfo):
            controlAlpha = 0
            controlHeight = 0
            isHeaderHidden = false
            bodyAlpha = 1
            bodyHeight = Self.connectionInfoBodyHeight
            connectionInfoChevronButton.image = Image(named: Image.stopProgressTemplateName)
            durationLabel.stringValue = connectionInfo.duration
            if let profileName = connectionInfo.profileName {
                profileTitleLabel.isHidden = false
                profileNameLabel.stringValue = profileName
            } else {
                profileTitleLabel.isHidden = true
                profileNameLabel.stringValue = ""
            }
            dataTransferredLabel.stringValue = connectionInfo.dataTransferred
            addressLabel.stringValue = connectionInfo.addresses
        }

        self.connectionInfoHeader.isHidden = isHeaderHidden

        let animatableChanges = {
            self.additionalControlContainer.layer?.opacity = controlAlpha
            self.additionalControlContainerHeightConstraint.constant = controlHeight
            self.connectionInfoBody.layer?.opacity = bodyAlpha
            self.connectionInfoBodyHeightConstraint.constant = bodyHeight
            self.bottomStackView.layoutSubtreeIfNeeded()
        }

        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3 /* seconds */
                context.allowsImplicitAnimation = true
                animatableChanges()
            }, completionHandler: nil)
        } else {
            animatableChanges()
        }
    }
}

extension ConnectionViewController: AuthorizingViewController {
    func showAuthorizingMessage(onCancelled: @escaping () -> Void) {
        parameters.environment.navigationController?
            .showAuthorizingMessage(onCancelled: onCancelled)
    }

    func hideAuthorizingMessage() {
        parameters.environment.navigationController?
            .hideAuthorizingMessage()
    }
}
