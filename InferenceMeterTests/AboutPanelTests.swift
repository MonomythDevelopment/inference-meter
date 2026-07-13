import Foundation
import Testing
@testable import InferenceMeter

@Test("About panel identifies Monomyth Development and public project details")
func aboutPanelIdentifiesMonomythDevelopmentAndProjectDetails() {
    let details = AboutPanelDetails.inferenceMeter

    #expect(details.organizationName == "Monomyth Development")
    #expect(details.websiteURL.absoluteString == "https://monomyth.dev")
    #expect(details.repositoryURL.absoluteString == "https://github.com/MonomythDevelopment/inference-meter")
    #expect(details.licenseURL.absoluteString.hasSuffix("/blob/main/LICENSE"))
}

@Test("About panel credits expose working website, repository, and license links")
func aboutPanelCreditsExposeExpectedLinks() {
    let details = AboutPanelDetails.inferenceMeter
    let credits = makeAboutPanelCredits(details: details)

    #expect(
        credits.string == """
        Built by Monomyth Development
        monomyth.dev
        Source code on GitHub
        Released under the MIT License
        """
    )
    #expect(link(in: credits, for: "monomyth.dev") == details.websiteURL)
    #expect(link(in: credits, for: "Source code on GitHub") == details.repositoryURL)
    #expect(link(in: credits, for: "Released under the MIT License") == details.licenseURL)
}

private func link(in attributedString: NSAttributedString, for text: String) -> URL? {
    let range = (attributedString.string as NSString).range(of: text)

    guard range.location != NSNotFound else {
        return nil
    }

    return attributedString.attribute(.link, at: range.location, effectiveRange: nil) as? URL
}
