import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum CredentialTemplate: String, CaseIterable {
    case api, githubApp, apple, ssh, cloud, database, custom

    var prototypeTitle: String {
        switch self {
        case .api: return appLocalized("API Access Credential")
        case .githubApp: return appLocalized("GitHub App")
        case .apple: return appLocalized("Apple Signing")
        case .ssh: return appLocalized("SSH Identity")
        case .cloud: return appLocalized("Cloud Account")
        case .database: return appLocalized("Database or Service Connection")
        case .custom: return appLocalized("Custom Credential")
        }
    }

    var prototypeDescription: String {
        switch self {
        case .api: return appLocalized("Access key and optional API endpoint")
        case .githubApp: return appLocalized("App ID, client secret, and private key file")
        case .apple: return appLocalized("For App Store Connect and automated signing")
        case .ssh: return appLocalized("Connect to servers or deploy code")
        case .cloud: return appLocalized("Access cloud platforms, storage, or CLIs")
        case .database: return appLocalized("Server, account, and password as one set")
        case .custom: return appLocalized("Add text or file values with keys, like .env")
        }
    }

    var label: String {
        switch self {
        case .custom: return appLocalized("Custom credential")
        case .api: return appLocalized("API credential")
        case .githubApp: return appLocalized("GitHub App")
        case .apple: return appLocalized("Apple signing")
        case .ssh: return appLocalized("SSH identity")
        case .cloud: return appLocalized("Cloud account")
        case .database: return appLocalized("Database connection")
        }
    }

    var components: [CredentialComponentDraft] {
        switch self {
        case .custom:
            return [CredentialComponentDraft(), CredentialComponentDraft(isOptional: true)]
        case .api:
            return [
                CredentialComponentDraft(name: "API_KEY", isSecret: true, isRemovable: false),
                CredentialComponentDraft(
                    name: "API_ENDPOINT",
                    isOptional: true,
                    emptyValuePolicy: .omitWhenNameIs("API_ENDPOINT")
                ),
            ]
        case .githubApp:
            return [
                CredentialComponentDraft(name: "GITHUB_APP_ID", isRemovable: false),
                CredentialComponentDraft(name: "GITHUB_CLIENT_ID"),
                CredentialComponentDraft(name: "GITHUB_CLIENT_SECRET", isSecret: true),
                CredentialComponentDraft(name: "GITHUB_PRIVATE_KEY", kind: .file),
                CredentialComponentDraft(
                    name: "GITHUB_INSTALLATION_ID",
                    isOptional: true,
                    emptyValuePolicy: .omitWhenNameIs("GITHUB_INSTALLATION_ID")
                ),
            ]
        case .apple:
            return [
                CredentialComponentDraft(name: "ISSUER_ID"),
                CredentialComponentDraft(name: "KEY_ID"),
                CredentialComponentDraft(name: "TEAM_ID"),
                CredentialComponentDraft(name: "PRIVATE_KEY_FILE", kind: .file),
            ]
        case .ssh:
            return [
                CredentialComponentDraft(name: "SSH_HOST"),
                CredentialComponentDraft(name: "SSH_USER"),
                CredentialComponentDraft(name: "SSH_PRIVATE_KEY", kind: .file),
                CredentialComponentDraft(name: "SSH_PASSPHRASE", isSecret: true, isOptional: true, emptyValuePolicy: .omitWhenNameIs("SSH_PASSPHRASE")),
            ]
        case .cloud:
            return [
                CredentialComponentDraft(name: "ACCESS_KEY_ID", isSecret: true),
                CredentialComponentDraft(name: "SECRET_ACCESS_KEY", isSecret: true),
                CredentialComponentDraft(name: "SESSION_TOKEN", isSecret: true, isOptional: true, emptyValuePolicy: .omitWhenNameIs("SESSION_TOKEN")),
                CredentialComponentDraft(name: "REGION", isOptional: true, emptyValuePolicy: .omitWhenNameIs("REGION")),
            ]
        case .database:
            return [
                CredentialComponentDraft(name: "DB_HOST"),
                CredentialComponentDraft(name: "DB_PORT"),
                CredentialComponentDraft(name: "DB_USER"),
                CredentialComponentDraft(name: "DB_PASSWORD", isSecret: true),
                CredentialComponentDraft(name: "DB_CERT", kind: .file, isOptional: true, emptyValuePolicy: .omitWhenNameIs("DB_CERT")),
            ]
        }
    }

    static func fieldTitle(for storageName: String) -> String {
        switch storageName {
        case "API_KEY": return appLocalized("Access Key")
        case "API_ENDPOINT": return appLocalized("API Endpoint")
        case "ISSUER_ID": return "Issuer ID"
        case "KEY_ID": return "Key ID"
        case "TEAM_ID": return "Team ID"
        case "GITHUB_APP_ID": return "App ID"
        case "GITHUB_CLIENT_ID": return "Client ID"
        case "GITHUB_CLIENT_SECRET": return appLocalized("Client Secret")
        case "GITHUB_INSTALLATION_ID": return appLocalized("Installation ID")
        case "PRIVATE_KEY_FILE", "SSH_PRIVATE_KEY", "GITHUB_PRIVATE_KEY": return appLocalized("Private Key File")
        case "SSH_HOST", "DB_HOST": return appLocalized("Server Address")
        case "SSH_USER", "DB_USER": return appLocalized("Username")
        case "SSH_PASSPHRASE": return appLocalized("Private Key Passphrase")
        case "ACCESS_KEY_ID": return appLocalized("Access Key ID")
        case "SECRET_ACCESS_KEY": return appLocalized("Secret Access Key")
        case "SESSION_TOKEN": return appLocalized("Session Token")
        case "REGION": return appLocalized("Region")
        case "DB_PORT": return appLocalized("Port")
        case "DB_PASSWORD": return appLocalized("Password")
        case "DB_CERT": return appLocalized("Certificate File")
        case "FILE", "文件": return appLocalized("File")
        default: return storageName
        }
    }
}
