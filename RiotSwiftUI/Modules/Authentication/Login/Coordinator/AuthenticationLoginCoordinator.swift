//
// Copyright 2021 New Vector Ltd
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import SwiftUI
import CommonKit
import MatrixSDK

struct AuthenticationLoginCoordinatorParameters {
    let navigationRouter: NavigationRouterType
    let authenticationService: AuthenticationService
    /// The login mode to allow SSO buttons to be shown when available.
    let loginMode: LoginMode
}

enum AuthenticationLoginCoordinatorResult {
    /// Continue using the supplied SSO provider.
    case continueWithSSO(SSOIdentityProvider)
    /// Login was successful with the associated session created.
    case success(session: MXSession, password: String?)
}

final class AuthenticationLoginCoordinator: Coordinator, Presentable {
    
    // MARK: - Properties
    
    // MARK: Private
    
    private let parameters: AuthenticationLoginCoordinatorParameters
    private let authenticationLoginHostingController: VectorHostingController
    private var authenticationLoginViewModel: AuthenticationLoginViewModelProtocol
    
    private var currentTask: Task<Void, Error>? {
        willSet {
            currentTask?.cancel()
        }
    }
    
    private var navigationRouter: NavigationRouterType { parameters.navigationRouter }
    private var indicatorPresenter: UserIndicatorTypePresenterProtocol
    private var waitingIndicator: UserIndicator?
    
    /// The authentication service used for the login.
    private var authenticationService: AuthenticationService { parameters.authenticationService }
    /// The wizard used to handle the login flow. Will only be `nil` if there is a misconfiguration.
    private var loginWizard: LoginWizard? { parameters.authenticationService.loginWizard }
    
    // MARK: Public

    // Must be used only internally
    var childCoordinators: [Coordinator] = []
    var callback: (@MainActor (AuthenticationLoginCoordinatorResult) -> Void)?
    
    // MARK: - Setup
    
    @MainActor init(parameters: AuthenticationLoginCoordinatorParameters) {
        self.parameters = parameters
        
        let homeserver = parameters.authenticationService.state.homeserver
        let viewModel = AuthenticationLoginViewModel(homeserver: homeserver.viewData)
        authenticationLoginViewModel = viewModel
        
        let view = AuthenticationLoginScreen(viewModel: viewModel.context)
        authenticationLoginHostingController = VectorHostingController(rootView: view)
        authenticationLoginHostingController.vc_removeBackTitle()
        authenticationLoginHostingController.enableNavigationBarScrollEdgeAppearance = true
        
        indicatorPresenter = UserIndicatorTypePresenter(presentingViewController: authenticationLoginHostingController)
    }
    
    // MARK: - Public
    func start() {
        MXLog.debug("[AuthenticationLoginCoordinator] did start.")
        Task { await setupViewModel() }
    }
    
    func toPresentable() -> UIViewController {
        authenticationLoginHostingController
    }
    
    // MARK: - Private
    
    /// Set up the view model. This method is extracted from `start()` so it can run on the `MainActor`.
    @MainActor private func setupViewModel() {
        authenticationLoginViewModel.callback = { [weak self] result in
            guard let self = self else { return }
            MXLog.debug("[AuthenticationLoginCoordinator] AuthenticationLoginViewModel did callback with result: \(result).")
            
            switch result {
            case .selectServer:
                self.presentServerSelectionScreen()
            case .parseUsername(let username):
                self.parseUsername(username)
            case .forgotPassword:
                #warning("Show the forgot password flow.")
            case .login(let username, let password):
                self.login(username: username, password: password)
            case .continueWithSSO(let identityProvider):
                self.callback?(.continueWithSSO(identityProvider))
            case .fallback:
                self.showFallback()
            }
        }
    }
    
    /// Show a blocking activity indicator whilst saving.
    @MainActor private func startLoading(isInteractionBlocking: Bool) {
        waitingIndicator = indicatorPresenter.present(.loading(label: VectorL10n.loading, isInteractionBlocking: isInteractionBlocking))
        
        if !isInteractionBlocking {
            authenticationLoginViewModel.update(isLoading: true)
        }
    }
    
    /// Hide the currently displayed activity indicator.
    @MainActor private func stopLoading() {
        authenticationLoginViewModel.update(isLoading: false)
        waitingIndicator = nil
    }
    
    /// Login with the supplied username and password.
    @MainActor private func login(username: String, password: String) {
        guard let loginWizard = loginWizard else {
            MXLog.failure("[AuthenticationLoginCoordinator] The login wizard was requested before getting the login flow.")
            return
        }
        
        startLoading(isInteractionBlocking: true)
        
        currentTask = Task { [weak self] in
            do {
                let session = try await loginWizard.login(login: username,
                                                          password: password,
                                                          initialDeviceName: UIDevice.current.initialDisplayName)
                
                guard !Task.isCancelled else { return }
                callback?(.success(session: session, password: password))
                
                self?.stopLoading()
            } catch {
                self?.stopLoading()
                self?.handleError(error)
            }
        }
    }
    
    /// Processes an error to either update the flow or display it to the user.
    @MainActor private func handleError(_ error: Error) {
        if let mxError = MXError(nsError: error as NSError) {
            authenticationLoginViewModel.displayError(.mxError(mxError.error))
            return
        }
        
        if let authenticationError = error as? AuthenticationError {
            switch authenticationError {
            case .invalidHomeserver:
                authenticationLoginViewModel.displayError(.invalidHomeserver)
            case .loginFlowNotCalled:
                #warning("Reset the flow")
            case .missingMXRestClient:
                #warning("Forget the soft logout session")
            }
            return
        }
        
        authenticationLoginViewModel.displayError(.unknown)
    }
    
    @MainActor private func parseUsername(_ username: String) {
        guard MXTools.isMatrixUserIdentifier(username) else { return }
        let domain = username.split(separator: ":")[1]
        let homeserverAddress = HomeserverAddress.sanitized(String(domain))
        
        startLoading(isInteractionBlocking: false)
        
        currentTask = Task { [weak self] in
            do {
                try await authenticationService.startFlow(.login, for: homeserverAddress)
                
                guard !Task.isCancelled else { return }
                
                updateViewModel()
                self?.stopLoading()
            } catch {
                self?.stopLoading()
                self?.handleError(error)
            }
        }
    }
    
    /// Presents the server selection screen as a modal.
    @MainActor private func presentServerSelectionScreen() {
        MXLog.debug("[AuthenticationLoginCoordinator] presentServerSelectionScreen")
        let parameters = AuthenticationServerSelectionCoordinatorParameters(authenticationService: authenticationService,
                                                                            flow: .login,
                                                                            hasModalPresentation: true)
        let coordinator = AuthenticationServerSelectionCoordinator(parameters: parameters)
        coordinator.callback = { [weak self, weak coordinator] result in
            guard let self = self, let coordinator = coordinator else { return }
            self.serverSelectionCoordinator(coordinator, didCompleteWith: result)
        }
        
        coordinator.start()
        add(childCoordinator: coordinator)
        
        let modalRouter = NavigationRouter()
        modalRouter.setRootModule(coordinator)
        
        navigationRouter.present(modalRouter, animated: true)
    }
    
    /// Handles the result from the server selection modal, dismissing it after updating the view.
    @MainActor private func serverSelectionCoordinator(_ coordinator: AuthenticationServerSelectionCoordinator,
                                                       didCompleteWith result: AuthenticationServerSelectionCoordinatorResult) {
        navigationRouter.dismissModule(animated: true) { [weak self] in
            if result == .updated {
                self?.updateViewModel()
            }

            self?.remove(childCoordinator: coordinator)
        }
    }
    
    /// Updates the view model to reflect any changes made to the homeserver.
    @MainActor private func updateViewModel() {
        let homeserver = authenticationService.state.homeserver
        authenticationLoginViewModel.update(homeserver: homeserver.viewData)

        if homeserver.needsFallback {
            showFallback()
        }
    }

    private func showFallback() {
        let url = authenticationService.fallbackURL(for: .login)

        MXLog.debug("[AuthenticationLoginCoordinator] showFallback, url: \(url)")

        guard let fallbackVC = AuthFallBackViewController(url: url.absoluteString) else {
            MXLog.error("[AuthenticationLoginCoordinator] showFallback: could not create fallback view controller")
            return
        }
        fallbackVC.delegate = self
        let navController = RiotNavigationController(rootViewController: fallbackVC)
        navController.navigationBar.topItem?.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel,
                                                                                 target: self,
                                                                                 action: #selector(dismissFallback))
        navigationRouter.present(navController, animated: true)
    }

    @objc
    private func dismissFallback() {
        MXLog.debug("[AuthenticationLoginCoorrdinator] dismissFallback")

        guard let fallbackNavigationVC = navigationRouter.toPresentable().presentedViewController as? RiotNavigationController else {
            return
        }
        fallbackNavigationVC.dismiss(animated: true)
        authenticationService.reset()
    }
}


// MARK: - AuthFallBackViewControllerDelegate
extension AuthenticationLoginCoordinator: AuthFallBackViewControllerDelegate {
    @MainActor func authFallBackViewController(_ authFallBackViewController: AuthFallBackViewController,
                                               didLoginWith loginResponse: MXLoginResponse) {
        let credentials = MXCredentials(loginResponse: loginResponse, andDefaultCredentials: nil)
        let client = MXRestClient(credentials: credentials)
        guard let session = MXSession(matrixRestClient: client) else {
            MXLog.error("[AuthenticationCoordinator] authFallBackViewController:didLogin: session could not be created")
            return
        }
        dismissFallback()
        callback?(.success(session: session, password: nil))
    }

    func authFallBackViewControllerDidClose(_ authFallBackViewController: AuthFallBackViewController) {
        dismissFallback()
    }

}
