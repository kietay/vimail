import AppKit
import GmailProvider
import MailCore
import VimailLog

/// Switching between dummy data and Gmail, and Gmail sign-in.
extension AppModel {
    /// The connected Gmail address, if any (it may be signed out).
    var gmailAccount: String? {
        if !settings.gmailAccount.isEmpty { return settings.gmailAccount }
        // Debug builds can run on a token file instead of a sign-in; show that account.
        if services.isGmail, !account.email.isEmpty { return account.email }
        return nil
    }

    func switchDataSource(_ source: DataSource) {
        guard source != settings.dataSource else { return }
        if source == .gmail, gmailAccount == nil {
            connectGmail()
            return
        }
        settings.dataSource = source
        Task {
            await reopenAccount()
            showToast(source == .gmail ? "Switched to \(settings.gmailAccount)." : "Switched to dummy data.")
        }
    }

    /// Opens Google sign-in in the browser. Also renews an expired sign-in (same account, same local mail).
    func connectGmail() {
        guard signInTask == nil else {
            showToast("Finish signing in to Google in your browser, or cancel from the command menu.")
            return
        }
        let client: GoogleOAuthClient
        do {
            guard let loaded = try GmailAccounts.loadClient() ?? GmailAccounts.chooseClientFile() else { return }
            client = loaded
        } catch {
            showToast(error.localizedDescription, isError: true)
            return
        }
        signingIn = true
        AppModel.log.info("Sign-in started\(hintDescription)")
        showToast("Sign in to Google in your browser…")
        let hint = gmailAccount
        signInTask = Task {
            defer {
                signingIn = false
                signInTask = nil
            }
            do {
                let credential = try await GmailAccounts.signIn(client: client, loginHint: hint)
                settings.gmailAccount = credential.email
                settings.dataSource = .gmail
                await reopenAccount()
                showToast(credential.allowsChanges ? "Connected \(credential.email)." : "Connected \(credential.email) (read only).")
            } catch GoogleOAuthError.cancelled {
                AppModel.log.info("Sign-in cancelled")
                showToast("Sign-in cancelled.")
            } catch {
                AppModel.log.error("Sign-in failed: \(error)")
                showToast((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, isError: true)
            }
        }
    }

    private var hintDescription: String { gmailAccount.map { " for \($0)" } ?? "" }

    /// Opens the log file (Console.app shows it live).
    func openLogFile() {
        guard let url = LogFile.shared.url else { return }
        NSWorkspace.shared.open(url)
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    func confirmSignOut() {
        guard let email = gmailAccount else { return }
        overlay = .confirm(Confirmation(
            title: "Sign out of \(email)?",
            message: "vimail forgets its access to this Gmail account and switches to dummy data. Mail and drafts stored on this Mac stay; sign in again to continue where you left off.",
            confirmTitle: "Sign out",
            action: .signOut
        ))
    }

    func signOutGmail() {
        guard let email = gmailAccount else { return }
        Task {
            await GmailAccounts.signOut(email: email)
            settings.gmailAccount = ""
            settings.dataSource = .dummy
            await reopenAccount()
            showToast("Signed out of \(email).")
        }
    }
}
