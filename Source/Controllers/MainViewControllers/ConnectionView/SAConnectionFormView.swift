//
//  SAConnectionFormView.swift
//  Sequel Ace
//
//  SwiftUI connection configuration form separating Connection Method (transport)
//  from Authentication Method, rendered in Sequel Ace's classic centered framed
//  two-column layout (no tabs).
//
//  App-target only: touches SPFavoriteColorSupport, AWSIAMAuthManager,
//  AWSDirectoryBookmarkManager, SecureBookmarkManager, and SPConnectionController.
//

import SwiftUI
import AppKit
import Combine

/// Shared layout constants for the centered framed connection form.
private enum SAConnectionFormLayout {
    static let frameWidth: CGFloat = 480
    static let labelWidth: CGFloat = 122
    static let rowSpacing: CGFloat = 8
    static let columnSpacing: CGFloat = 10
}

/// A classic macOS two-column form row: right-aligned label on the left,
/// flexible control on the right.
private struct SAFormRow<Content: View>: View {
    let label: String
    let alignment: VerticalAlignment
    @ViewBuilder let content: () -> Content

    init(_ label: String, alignment: VerticalAlignment = .firstTextBaseline, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.alignment = alignment
        self.content = content
    }

    var body: some View {
        HStack(alignment: alignment, spacing: SAConnectionFormLayout.columnSpacing) {
            Text(label)
                .foregroundColor(.primary)
                .frame(width: SAConnectionFormLayout.labelWidth, alignment: .trailing)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Indents option toggles / secondary notes to align with the right-hand control column.
private struct SAFormIndentedRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SAConnectionFormLayout.columnSpacing) {
            Color.clear
                .frame(width: SAConnectionFormLayout.labelWidth, height: 1)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// SwiftUI editor for connection details, separating Connection Method (transport)
/// from Authentication Method so combinations such as AWS IAM over SSH Tunnel
/// work cleanly in a single compact framed box without tabs.
struct SAConnectionFormView: View {

    @ObservedObject var model: SAConnectionFormModel

    /// When true (standalone window), renders a Connect button below the frame.
    /// Embedded hosts (SPConnectionController) render their own action bar below the frame.
    var showsStandaloneConnectButton: Bool = true

    /// Disables form editing while a connection attempt is in progress.
    var isDisabled: Bool = false

    /// Optional host-provided handler for authorizing `~/.aws`. When nil, the
    /// form opens an NSOpenPanel directly.
    var onAuthorizeAWSDirectory: (() -> Void)? = nil

    /// Invoked when the user submits a form that passed validation —
    /// the host initiates the connection (C3: via SAConnectionService).
    var onConnect: (SAConnectionFormModel) -> Void = { _ in }

    @State private var validationFailure: SAConnectionValidationFailure?
    @State private var isPresentingValidationFailure = false

    /// Tracks the Vault Role field so losing focus can commit a pasted path.
    @FocusState private var roleFieldFocused: Bool

    /// Ensures the `~/.aws` authorization dialog is only auto-prompted once per session
    /// when the user selects AWS IAM.
    private static var hasAutoPromptedAWSAuthThisSession = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                framedFormCard

                if showsStandaloneConnectButton {
                    HStack {
                        Spacer()
                        Button {
                            submit()
                        } label: {
                            Text("Connect", comment: "connection view : connect button")
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canAttemptConnection)
                    }
                    .frame(width: SAConnectionFormLayout.frameWidth)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .disabled(isDisabled)
        .onChange(of: model.authMethod) { newMethod in
            guard newMethod == .awsIAM,
                  !Self.hasAutoPromptedAWSAuthThisSession,
                  !AWSDirectoryBookmarkManager.shared.isAWSDirectoryAuthorized else { return }
            Self.hasAutoPromptedAWSAuthThisSession = true
            DispatchQueue.main.async {
                if let onAuthorizeAWSDirectory {
                    onAuthorizeAWSDirectory()
                } else {
                    SAAWSIAMSettingsRows.presentAWSDirectoryAuthorizationPanel()
                }
            }
        }
        .alert(
            validationFailure?.alertTitle ?? "",
            isPresented: $isPresentingValidationFailure,
            presenting: validationFailure
        ) { _ in
            Button {
                // Dismissal is driven by the isPresented binding; nothing to do.
            } label: {
                Text("OK", comment: "OK button")
            }
        } message: { failure in
            Text(failure.alertMessage)
        }
    }

    // MARK: - Framed Card

    private var framedFormCard: some View {
        VStack(alignment: .leading, spacing: SAConnectionFormLayout.rowSpacing) {
            identityAndConnectionBlock
            Divider().padding(.vertical, 4)
            serverBlock
            if model.connectionMethod == .sshTunnel {
                Divider().padding(.vertical, 4)
                sshTunnelBlock
            }
            Divider().padding(.vertical, 4)
            credentialsBlock
            Divider().padding(.vertical, 4)
            optionsBlock
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(width: SAConnectionFormLayout.frameWidth)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    // MARK: - Form Blocks

    /// Name, classic horizontal color dots, and Connection Method dropdown.
    private var identityAndConnectionBlock: some View {
        Group {
            SAFormRow(NSLocalizedString("Name", comment: "connection view : field label") + ":") {
                TextField("", text: $model.info.name, prompt: Text(namePrompt))
            }

            SAFormRow(NSLocalizedString("Colour", comment: "connection view : field label") + ":", alignment: .center) {
                SAFavoriteColorPicker(colorIndex: $model.info.colorIndex)
            }

            SAFormRow(NSLocalizedString("Connection Method", comment: "connection view : connection method dropdown label") + ":") {
                Picker("", selection: $model.connectionMethod) {
                    Text("TCP/IP", comment: "connection type : tcp/ip").tag(SAConnectionMethod.tcpIP)
                    Text("Socket", comment: "connection type : socket").tag(SAConnectionMethod.socket)
                    Text("SSH Tunnel", comment: "connection type : ssh tunnel").tag(SAConnectionMethod.sshTunnel)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    /// Server / database endpoint fields, adapted to the selected connection method.
    @ViewBuilder
    private var serverBlock: some View {
        switch model.connectionMethod {
        case .socket:
            SAFormRow(NSLocalizedString("Socket", comment: "connection view : field label") + ":") {
                TextField("", text: $model.info.socket, prompt: optionalPrompt)
            }
            databaseRow

        case .tcpIP:
            SAFormRow(NSLocalizedString("Host", comment: "connection view : field label") + ":") {
                TextField("", text: $model.info.host, prompt: hostPrompt)
            }
            portRow
            databaseRow

        case .sshTunnel:
            SAFormRow(NSLocalizedString("MySQL Host", comment: "connection view : field label") + ":") {
                TextField("", text: $model.info.host, prompt: hostPrompt)
            }
            portRow
            databaseRow
            if model.showsRemoteSocketField {
                SAFormRow(NSLocalizedString("Remote Socket", comment: "connection view : field label") + ":") {
                    TextField("", text: $model.info.sshRemoteSocketPath, prompt: optionalPrompt)
                }
            }
        }
    }

    /// SSH tunnel settings, shown only when SSH Tunnel is selected.
    private var sshTunnelBlock: some View {
        Group {
            SAFormRow(NSLocalizedString("SSH Host", comment: "connection view : field label") + ":") {
                TextField("", text: $model.info.sshHost)
            }
            SAFormRow(NSLocalizedString("SSH User", comment: "connection view : field label") + ":") {
                TextField("", text: $model.info.sshUser)
            }
            SAFormRow(NSLocalizedString("SSH Password", comment: "connection view : field label") + ":") {
                SARevealableSecureField(text: $model.info.sshPassword)
            }
            SAFormRow(NSLocalizedString("SSH Port", comment: "connection view : field label") + ":") {
                TextField("", text: $model.info.sshPort, prompt: optionalPrompt)
                    .frame(width: 90)
            }
            SAFormRow(NSLocalizedString("SSH Key", comment: "connection view : ssh key label") + ":", alignment: .top) {
                SAOptionalFileRow(
                    kind: .sshKey,
                    isEnabled: $model.sshKeyLocationEnabled,
                    path: $model.info.sshKeyLocation
                )
            }
        }
    }

    /// Authentication dropdown + credential fields directly together.
    private var credentialsBlock: some View {
        Group {
            SAFormRow(NSLocalizedString("Authentication", comment: "connection view : authentication method dropdown label") + ":") {
                Picker("", selection: $model.authMethod) {
                    ForEach(model.availableAuthMethods, id: \.self) { method in
                        authMethodLabel(for: method).tag(method)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            switch model.authMethod {
            case .password:
                SAFormRow(NSLocalizedString("Username", comment: "connection view : field label") + ":") {
                    TextField("", text: $model.info.user)
                }
                SAFormRow(NSLocalizedString("Password", comment: "connection view : field label") + ":") {
                    SARevealableSecureField(text: $model.info.password)
                }

            case .awsIAM:
                SAFormRow(NSLocalizedString("Username", comment: "connection view : field label") + ":") {
                    TextField("", text: $model.info.user)
                }
                SAAWSIAMSettingsRows(
                    profile: $model.info.awsProfile,
                    region: $model.info.awsRegion,
                    onAuthorizeAWSDirectory: onAuthorizeAWSDirectory
                )

            case .vault:
                SAFormRow(NSLocalizedString("Vault host", comment: "connection view : field label") + ":") {
                    TextField("", text: $model.info.vaultHost)
                }
                SAFormRow(NSLocalizedString("Vault port", comment: "connection view : field label") + ":") {
                    TextField("", text: $model.info.vaultPort, prompt: Text(verbatim: "443"))
                        .frame(width: 90)
                }
                SAFormRow(NSLocalizedString("OIDC Mount", comment: "connection view : field label") + ":") {
                    TextField("", text: $model.info.vaultOIDCMount, prompt: Text(verbatim: "oidc"))
                }
                SAFormRow(NSLocalizedString("Vault mount", comment: "connection view : field label") + ":") {
                    TextField("", text: $model.vaultMount, prompt: Text(verbatim: "databases_credentials"))
                }
                SAFormRow(NSLocalizedString("Role", comment: "connection view : field label") + ":") {
                    TextField("", text: $model.vaultCredentialsRole)
                        .focused($roleFieldFocused)
                        .onSubmit { model.commitVaultCredentialsRole() }
                        .onChange(of: roleFieldFocused) { isFocused in
                            if !isFocused { model.commitVaultCredentialsRole() }
                        }
                }
            }
        }
    }

    /// Time Zone + Security / SSL checkboxes.
    private var optionsBlock: some View {
        Group {
            SAFormRow(NSLocalizedString("Time Zone", comment: "connection view : field label") + ":") {
                SATimeZonePicker(choice: model.timeZoneChoice) { newChoice in
                    model.timeZoneChoice = newChoice
                }
                .equatable()
            }

            SAFormIndentedRow {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $model.allowDataLocalInfile) {
                        Text("Allow LOCAL_DATA_INFILE (insecure)", comment: "connection view : allow local data infile checkbox")
                    }

                    if model.showsClearTextPluginToggle {
                        Toggle(isOn: $model.enableClearTextPlugin) {
                            Text("Enable Cleartext plugin (insecure)", comment: "connection view : enable cleartext plugin checkbox")
                        }
                    }

                    if model.showsRequestServerPublicKeyToggle {
                        Toggle(isOn: $model.requestServerPublicKey) {
                            Text("Get Public Key", comment: "connection view : get server public key checkbox")
                        }
                        .help(NSLocalizedString("Request the server RSA public key for caching_sha2_password over non-SSL connections.",
                                                comment: "connection view : get server public key help"))
                    }

                    if model.showsSSLToggle {
                        Toggle(isOn: $model.useSSL) {
                            Text("Require SSL", comment: "connection view : require ssl checkbox")
                        }
                    }

                    if model.forcesSSL {
                        Text("SSL/TLS and cleartext plugins are enabled automatically for AWS IAM connections.",
                             comment: "connection view : aws iam security note")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if model.showsSSLFileOptions {
                VStack(alignment: .leading, spacing: 6) {
                    SAFormRow(NSLocalizedString("Key File", comment: "connection view : ssl key file label") + ":", alignment: .top) {
                        SAOptionalFileRow(
                            kind: .sslKey,
                            isEnabled: $model.sslKeyFileLocationEnabled,
                            path: $model.info.sslKeyFileLocation
                        )
                    }
                    SAFormRow(NSLocalizedString("Certificate", comment: "connection view : ssl certificate label") + ":", alignment: .top) {
                        SAOptionalFileRow(
                            kind: .sslCertificate,
                            isEnabled: $model.sslCertificateFileLocationEnabled,
                            path: $model.info.sslCertificateFileLocation
                        )
                    }
                    SAFormRow(NSLocalizedString("CA Cert", comment: "connection view : ssl ca cert label") + ":", alignment: .top) {
                        SAOptionalFileRow(
                            kind: .sslCACert,
                            isEnabled: $model.sslCACertFileLocationEnabled,
                            path: $model.info.sslCACertFileLocation
                        )
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Shared rows & helpers

    @ViewBuilder
    private func authMethodLabel(for method: SAAuthMethod) -> some View {
        switch method {
        case .password:
            Text("Username & Password", comment: "auth method : username and password")
        case .awsIAM:
            Text("AWS IAM", comment: "connection type : aws iam")
        case .vault:
            Text("Vault", comment: "connection type : vault")
        }
    }

    private var hostPrompt: Text? {
        switch model.authMethod {
        case .awsIAM, .vault:
            return Text(verbatim: "e.g. mydb.us-east-1.rds.amazonaws.com")
        case .password:
            return nil
        }
    }

    private var databaseRow: some View {
        SAFormRow(NSLocalizedString("Database", comment: "connection view : field label") + ":") {
            TextField("", text: $model.info.database, prompt: optionalPrompt)
        }
    }

    private var portRow: some View {
        SAFormRow(NSLocalizedString("Port", comment: "connection view : field label") + ":") {
            TextField("", text: $model.info.port, prompt: Text(verbatim: "3306"))
                .frame(width: 90)
        }
    }

    private var optionalPrompt: Text {
        Text("optional", comment: "connection view : optional field placeholder")
    }

    private var namePrompt: String {
        if let generated = model.generatedName, !generated.isEmpty {
            return generated
        }
        return NSLocalizedString("Optional Name", comment: "connection view : name field placeholder")
    }

    private func submit() {
        if let failure = model.validate() {
            validationFailure = failure
            isPresentingValidationFailure = true
            return
        }
        onConnect(model)
    }
}

// MARK: - Time-zone picker

/// The time-zone menu as its own invalidation boundary.
private struct SATimeZonePicker: View, Equatable {

    let choice: SATimeZoneChoice
    let onSelect: (SATimeZoneChoice) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.choice == b.choice
    }

    private static let menu = SATimeZoneMenuEntry.menu()

    var body: some View {
        Picker("", selection: selection) {
            ForEach(Self.menu, id: \.self) { entry in
                switch entry {
                case .choice(.server):
                    Text("Use Server Time Zone", comment: "Leave the server time zone in place when connecting")
                        .tag(SATimeZoneChoice.server)
                case .choice(.system):
                    Text("Use System Time Zone", comment: "Set the time zone currently used by the user when connecting")
                        .tag(SATimeZoneChoice.system)
                case .choice(.fixed(let identifier)):
                    Text(verbatim: identifier).tag(SATimeZoneChoice.fixed(identifier))
                case .separator:
                    Divider()
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private var selection: Binding<SATimeZoneChoice> {
        Binding(get: { choice }, set: { onSelect($0) })
    }
}

// MARK: - Classic horizontal colour dots (SPColorSelectorView style)

/// Horizontal row of clickable coloured dots matching the classic `SPColorSelectorView`.
/// Clicking the currently selected dot deselects it back to `-1` (no colour).
private struct SAFavoriteColorPicker: View {

    @Binding var colorIndex: Int
    @State private var hoveredIndex: Int? = nil

    private static let noColorIndex = -1

    private var colors: [NSColor] {
        SPFavoriteColorSupport.sharedInstance().userColorList ?? []
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, nsColor in
                let isSelected = (colorIndex == index)
                let isHovered = (hoveredIndex == index)
                Button {
                    colorIndex = isSelected ? Self.noColorIndex : index
                } label: {
                    ZStack {
                        if isSelected || isHovered {
                            Circle()
                                .stroke(isSelected ? Color(nsColor: .controlAccentColor) : Color.secondary.opacity(0.5),
                                        lineWidth: isSelected ? 2 : 1)
                                .frame(width: 18, height: 18)
                        }
                        Circle()
                            .fill(Color(nsColor: nsColor))
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle()
                                    .stroke(Color.black.opacity(0.2), lineWidth: 0.5)
                            )
                    }
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredIndex = hovering ? index : (hoveredIndex == index ? nil : hoveredIndex)
                }
                .accessibilityLabel(colorLabel(at: index))
            }

            if colorIndex != Self.noColorIndex {
                Button {
                    colorIndex = Self.noColorIndex
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("None", comment: "connection view : no favorite colour"))
            }
        }
    }

    private func colorLabel(at index: Int) -> String {
        String(format: NSLocalizedString("Colour %ld",
                                         comment: "connection view : favorite colour by position"),
               index + 1)
    }
}

// MARK: - Optional file row

private struct SAOptionalFileRow: View {

    let kind: SAConnectionFileKind
    @Binding var isEnabled: Bool
    @Binding var path: String

    @State private var rejection: SAConnectionFileRejection?
    @State private var isPresentingRejection = false

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .onChange(of: isEnabled) { isOn in
                    if !isOn { path = "" }
                }

            if isEnabled {
                Text(verbatim: path.isEmpty
                     ? NSLocalizedString("none set", comment: "connection view : no file chosen")
                     : (path as NSString).abbreviatingWithTildeInPath)
                    .foregroundColor(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    chooseFile()
                } label: {
                    Text("Choose…", comment: "connection view : choose file button")
                }
                .controlSize(.small)
            } else {
                Text("none set", comment: "connection view : no file chosen")
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .alert(
            rejection?.alertTitle ?? "",
            isPresented: $isPresentingRejection,
            presenting: rejection
        ) { _ in
            Button {} label: { Text("OK", comment: "OK button") }
        } message: { rejection in
            Text(rejection.alertMessage)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            isEnabled = false
            path = ""
            return
        }

        if let rejection = SAConnectionFileValidator.rejection(forFileAt: url, kind: kind) {
            self.rejection = rejection
            isPresentingRejection = true
            return
        }

        _ = SecureBookmarkManager.sharedInstance.addBookmarkFor(
            url: url,
            options: UInt(NSURL.BookmarkCreationOptions.withSecurityScope.rawValue
                          | NSURL.BookmarkCreationOptions.securityScopeAllowOnlyReadAccess.rawValue),
            isForStaleBookmark: false,
            isForKnownHostsFile: false
        )

        path = url.path
    }
}

// MARK: - Revealable password field

private struct SARevealableSecureField: View {

    @Binding var text: String
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 6) {
            if isRevealed {
                TextField("", text: $text)
            } else {
                SecureField("", text: $text)
            }
            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help(isRevealed
                  ? NSLocalizedString("Hide password", comment: "connection view : hide password tooltip")
                  : NSLocalizedString("Show password", comment: "connection view : show password tooltip"))
        }
    }
}

// MARK: - AWS IAM settings rows

private struct SAAWSIAMSettingsRows: View {

    @Binding var profile: String
    @Binding var region: String
    var onAuthorizeAWSDirectory: (() -> Void)?

    @State private var isAuthorized = AWSDirectoryBookmarkManager.shared.isAWSDirectoryAuthorized
    @State private var availableProfiles: [String] = []
    @State private var availableRegions: [String] = AWSIAMAuthManager.cachedOrFallbackRegions()

    private static let authChangedNotification = Notification.Name("AWSDirectoryAuthorizationChanged")

    var body: some View {
        Group {
            if isAuthorized {
                SAFormRow(NSLocalizedString("AWS Profile", comment: "connection view : field label") + ":") {
                    Picker("", selection: $profile) {
                        ForEach(profileOptions, id: \.self) { name in
                            Text(verbatim: name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                SAFormRow(NSLocalizedString("Region", comment: "connection view : field label") + ":") {
                    HStack(spacing: 4) {
                        TextField(
                            "",
                            text: $region,
                            prompt: Text("Auto-detect from hostname", comment: "connection view : aws region auto-detect placeholder")
                        )

                        Menu {
                            Button {
                                region = ""
                            } label: {
                                Text("Auto-detect", comment: "connection view : aws region auto-detect menu item")
                            }
                            Divider()
                            ForEach(availableRegions, id: \.self) { regionID in
                                Button(regionID) {
                                    region = regionID
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            } else {
                SAFormIndentedRow {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Authorize access to your ~/.aws directory to select an AWS profile.",
                             comment: "connection view : aws directory authorization prompt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            authorizeAWSDirectory()
                        } label: {
                            Text("Authorize ~/.aws Directory…", comment: "connection view : authorize aws directory button")
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .onAppear {
            reloadAWSState()
            AWSIAMAuthManager.refreshAWSRegionsIfNeeded { regions in
                if !regions.isEmpty {
                    availableRegions = regions
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.authChangedNotification)) { _ in
            reloadAWSState()
        }
    }

    private var profileOptions: [String] {
        var options = availableProfiles
        if options.isEmpty {
            options = ["default"]
        }
        let current = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty && !options.contains(current) {
            options.insert(current, at: 0)
        }
        return options
    }

    private func reloadAWSState() {
        isAuthorized = AWSDirectoryBookmarkManager.shared.isAWSDirectoryAuthorized
        availableProfiles = isAuthorized ? AWSIAMAuthManager.availableProfiles() : []
    }

    private func authorizeAWSDirectory() {
        if let onAuthorizeAWSDirectory {
            onAuthorizeAWSDirectory()
            return
        }

        if Self.presentAWSDirectoryAuthorizationPanel() {
            reloadAWSState()
        }
    }

    @discardableResult
    static func presentAWSDirectoryAuthorizationPanel() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true

        let homeDirectory = NSHomeDirectory()
        let awsDir = (homeDirectory as NSString).appendingPathComponent(".aws")
        let fm = FileManager.default
        if fm.fileExists(atPath: awsDir) {
            panel.directoryURL = URL(fileURLWithPath: awsDir)
        } else {
            panel.directoryURL = URL(fileURLWithPath: homeDirectory)
        }

        panel.message = NSLocalizedString("Select your .aws directory to enable AWS IAM authentication",
                                          comment: "AWS directory selection message")
        panel.prompt = NSLocalizedString("Authorize", comment: "AWS directory authorize button")

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let path = url.path
        let isValid = path.hasSuffix(".aws")
            || fm.fileExists(atPath: (path as NSString).appendingPathComponent("credentials"))
            || fm.fileExists(atPath: (path as NSString).appendingPathComponent("config"))

        guard isValid else { return false }

        if AWSDirectoryBookmarkManager.shared.addAWSDirectoryBookmark(from: url) {
            NotificationCenter.default.post(name: Self.authChangedNotification, object: nil)
            return true
        }
        return false
    }
}

// MARK: - Embedded Form Bridge (SPConnectionController)

/// Observable UI state for the embedded connection form's bottom action bar.
private final class SAEmbeddedConnectionFormState: ObservableObject {
    @Published var isConnecting: Bool = false
    @Published var canCancel: Bool = true
    @Published var canConnect: Bool = true
    @Published var statusText: String? = nil
    @Published var showEditButtons: Bool = false
    @Published var canSaveFavorite: Bool = false
}

/// Bridges `SPConnectionController` (ObjC) and `SAConnectionFormView` (SwiftUI),
/// hosting the tab-free SwiftUI form inside `SPConnectionController`'s right pane.
@objc final class SAConnectionFormBridge: NSObject {

    private let model = SAConnectionFormModel()
    private let state = SAEmbeddedConnectionFormState()
    private weak var controller: SPConnectionController?
    private var hostingView: NSView?
    private var isSyncingFromController = false
    private var cancellables: Set<AnyCancellable> = []

    @objc init(controller: SPConnectionController) {
        self.controller = controller
        super.init()

        let rootView = SAEmbeddedConnectionFormRootView(
            model: model,
            state: state,
            onConnect: { [weak controller] in
                controller?.initiateConnection(fromFormIsTesting: false)
            },
            onTestConnect: { [weak controller] in
                controller?.initiateConnection(fromFormIsTesting: true)
            },
            onCancel: { [weak controller] in
                controller?.cancelConnection(nil)
            },
            onSaveFavorite: { [weak controller] in
                controller?.saveFavorite(nil)
            },
            onAddFavorite: { [weak controller] in
                controller?.addFavoriteUsingCurrentDetails(nil)
            },
            onShowHelp: { [weak controller] in
                controller?.showHelp(nil)
            },
            onAuthorizeAWSDirectory: { [weak controller] in
                controller?.authorizeAWSDirectory(nil)
            }
        )

        self.hostingView = NSHostingView(rootView: rootView)

        model.$info
            .dropFirst()
            .sink { [weak self] newInfo in
                self?.handleFormEdit(newInfo)
            }
            .store(in: &cancellables)
    }

    /// Installs the SwiftUI form into the right pane of ConnectionView.xib,
    /// replacing the legacy tabbed `NSScrollView`.
    @objc(installReplacing:below:)
    func install(replacing legacyScrollView: NSView, below headerView: NSView?) {
        guard let container = legacyScrollView.superview,
              let hostingView else { return }

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)

        let topAnchor = headerView?.bottomAnchor ?? container.topAnchor
        let topConstant: CGFloat = headerView != nil ? 6 : 0

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor, constant: topConstant),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Remove the legacy tabbed scroll view so its hidden buttons and key
        // equivalents cannot intercept Return / Cmd+S / Tab focus.
        legacyScrollView.removeFromSuperview()
    }

    /// Shows or hides the form (e.g. hidden when a favorite group is selected).
    @objc func setHidden(_ hidden: Bool) {
        hostingView?.isHidden = hidden
    }

    /// Copies the controller's current connection properties into the SwiftUI
    /// model without counting the update as a user edit.
    @objc func syncFromController() {
        guard let controller else { return }

        isSyncingFromController = true
        defer { isSyncingFromController = false }

        var info = SAConnectionInfo()
        let legacyType = SAConnectionType(rawValue: controller.type) ?? .tcpIP
        switch legacyType {
        case .socket:
            info.connectionMethod = .socket
        case .sshTunnel:
            info.connectionMethod = .sshTunnel
        case .tcpIP, .awsIAM, .vault:
            info.connectionMethod = .tcpIP
        }
        info.authMethod = SAAuthMethod(rawValue: controller.authMethod) ?? .password
        if info.connectionMethod == .socket {
            info.authMethod = .password
        }
        info.name = controller.name ?? ""
        info.host = controller.host ?? ""
        info.user = controller.user ?? ""
        info.password = controller.password ?? ""
        info.database = controller.database ?? ""
        info.socket = controller.socket ?? ""
        info.port = controller.port ?? ""
        info.colorIndex = controller.colorIndex
        info.useCompression = controller.useCompression

        info.timeZoneMode = SAConnectionTimeZoneMode(rawValue: controller.timeZoneMode.rawValue) ?? .useServerTZ
        info.timeZoneIdentifier = controller.timeZoneIdentifier ?? ""

        info.allowDataLocalInfile = controller.allowDataLocalInfile
        info.enableClearTextPlugin = controller.enableClearTextPlugin
        info.requestServerPublicKey = controller.requestServerPublicKey

        info.useAWSIAMAuth = info.authMethod == .awsIAM ? 1 : 0
        info.awsRegion = controller.awsRegion ?? ""
        info.awsProfile = controller.awsProfile ?? ""

        info.vaultHost = controller.vaultHost ?? ""
        info.vaultPort = controller.vaultPort ?? ""
        info.vaultOIDCMount = controller.vaultOIDCMount ?? ""
        info.vaultCredentialsPath = controller.vaultCredentialsPath ?? ""

        info.useSSL = controller.useSSL
        info.sslKeyFileLocationEnabled = controller.sslKeyFileLocationEnabled
        info.sslKeyFileLocation = controller.sslKeyFileLocation ?? ""
        info.sslCertificateFileLocationEnabled = controller.sslCertificateFileLocationEnabled
        info.sslCertificateFileLocation = controller.sslCertificateFileLocation ?? ""
        info.sslCACertFileLocationEnabled = controller.sslCACertFileLocationEnabled
        info.sslCACertFileLocation = controller.sslCACertFileLocation ?? ""

        info.sshHost = controller.sshHost ?? ""
        info.sshUser = controller.sshUser ?? ""
        info.sshPassword = controller.sshPassword ?? ""
        info.sshKeyLocationEnabled = controller.sshKeyLocationEnabled
        info.sshKeyLocation = controller.sshKeyLocation ?? ""
        info.sshPort = controller.sshPort ?? ""
        info.sshRemoteSocketPath = controller.sshRemoteSocketPath ?? ""

        model.replaceInfo(info)
    }

    /// Updates the bottom action bar state (progress, connect/cancel, edit buttons).
    @objc func updateActionState(
        isConnecting: Bool,
        canCancel: Bool,
        canConnect: Bool,
        statusText: String?,
        showEditButtons: Bool,
        canSaveFavorite: Bool
    ) {
        let apply = { [state] in
            state.isConnecting = isConnecting
            state.canCancel = canCancel
            state.canConnect = canConnect
            state.statusText = statusText
            state.showEditButtons = showEditButtons
            state.canSaveFavorite = canSaveFavorite
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    // MARK: - Private

    private func handleFormEdit(_ info: SAConnectionInfo) {
        guard !isSyncingFromController, let controller else { return }

        controller.applyFormInfo(SAConnectionInfoObjC(info: info))
        controller.startEditingConnectionFromForm()
    }
}

private struct SAEmbeddedConnectionFormRootView: View {

    @ObservedObject var model: SAConnectionFormModel
    @ObservedObject var state: SAEmbeddedConnectionFormState

    var onConnect: () -> Void
    var onTestConnect: () -> Void
    var onCancel: () -> Void
    var onSaveFavorite: () -> Void
    var onAddFavorite: () -> Void
    var onShowHelp: () -> Void
    var onAuthorizeAWSDirectory: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SAConnectionFormView(
                model: model,
                showsStandaloneConnectButton: false,
                isDisabled: state.isConnecting,
                onAuthorizeAWSDirectory: onAuthorizeAWSDirectory
            )

            Divider()

            footerBar
                .frame(maxWidth: SAConnectionFormLayout.frameWidth)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
    }

    private var footerBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if state.isConnecting {
                    ProgressView()
                        .controlSize(.small)
                    if let statusText = state.statusText, !statusText.isEmpty {
                        Text(statusText)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Button {
                        onShowHelp()
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(NSLocalizedString("Show Help", comment: "connection view : help button tooltip"))

                    if let statusText = state.statusText, !statusText.isEmpty {
                        Text(statusText)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if state.isConnecting {
                    Button {
                        onCancel()
                    } label: {
                        Text("Cancel", comment: "cancel button")
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!state.canCancel)
                } else {
                    Button {
                        onConnect()
                    } label: {
                        Text("Connect", comment: "connection view : connect button")
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.canConnect)
                }
            }

            if state.showEditButtons && !state.isConnecting {
                HStack(spacing: 8) {
                    Button {
                        onAddFavorite()
                    } label: {
                        Text("Add to Favorites", comment: "connection view : add to favorites button")
                    }
                    .controlSize(.small)
                    .keyboardShortcut("a", modifiers: [.command, .option])

                    Button {
                        onSaveFavorite()
                    } label: {
                        Text("Save Changes", comment: "connection view : save changes button")
                    }
                    .controlSize(.small)
                    .disabled(!state.canSaveFavorite)
                    .keyboardShortcut("s", modifiers: .command)

                    Spacer()

                    Button {
                        onTestConnect()
                    } label: {
                        Text("Test Connection", comment: "connection view : test connection button")
                    }
                    .controlSize(.small)
                    .disabled(!state.canConnect)
                }
            }
        }
    }
}
